import schlib.getopt2;
import std.io;
import iopipe;
import iopipe.refc;
import std.getopt;
import std.range;
import std.string;
import std.path : extension;
import std.exception;
import std.conv;
import std.algorithm;
import std.experimental.allocator.mallocator;

enum symbolPostfix = "_CPPTOOL_KEEP";

// an iopipe of segments based on an internal pipe. Each "element" in this pipe is a segment of the underlying source, 
struct SegmentedPipe(SourceChain, Allocator = GCNoPointerAllocator)
{
    private {
        SourceChain source;
        AllocatedBuffer!(size_t, Allocator, 16) buffer;
    }

    private this(SourceChain source)
    {
        this.source = source;
        auto nelems = buffer.extend(1);
        assert(nelems == 1);
        buffer.window[0] = 0; // initialize with an offset of 0.
    }

    mixin implementValve!source;

    // the "range"
    static struct Window
    {
        private
        {
            SegmentedPipe *owner;
            size_t[] offsets; // all the offsets of each of the 
        }

        auto front() => this[0];
        
        auto back() => this[$-1];

        bool empty() => offsets.length < 2; // needs at least 2 offsets to properly slice

        void popFront() => offsets.popFront;

        void popBack() => offsets.popBack;

        size_t length() => offsets.length - 1;

        alias opDollar = length;

        auto opIndex(size_t idx)
        {
            immutable base = owner.buffer.window[0]; // first offset is always the front
            return owner.source.window[offsets[idx] - base .. offsets[idx + 1] - base];
        }
    }

    Window window() => Window(&this, buffer.window);

    size_t extend(size_t elements) {
        // ensure we can get a new element
        if(buffer.extend(1) == 0)
            return 0; // can't get any more buffer space!
        // always going to extend the source chain with 0, and give us a new segment
        auto baseElems = source.extend(0);
        if(baseElems == 0)
        {
            // no new data
            buffer.releaseBack(1);
            return 0;
        }
        buffer.window[$-1] = buffer.window[$-2] + baseElems;
        return 1;
    }

    void release(size_t elements)
    {
        source.release(buffer.window[elements] - buffer.window[0]);
        buffer.releaseFront(elements);
    }
}

auto segmentedPipe(Chain, Allocator = GCNoPointerAllocator)(Chain base)
{
    return SegmentedPipe!(Chain, Allocator)(base);
}

// C preprocessor directive flags
enum FLAGS {
    beginFile = 1 << 1,
    resumeFile = 1 << 2,
    systemFile = 1 << 3,
    treatAsC = 1 << 4
}

struct Directive
{
    const(char)[] filename;
    size_t linenum;
    size_t flags; // 1 << flagnum
    this(const(char)[] line)
    {
        // # <linenum> "<filename>" [flag [flag ...]]
        void chomp(string expected) {
            enforce(line.startsWith(expected), "Expected " ~ expected ~ " in line `" ~ line ~ "`");
            line = line[expected.length .. $];
        }
        chomp("# ");
        linenum = line.parse!size_t;
        chomp(" \"");
        // find the next "
        auto x = line.findSplit("\"");
        enforce(x, "Could not find second quote!");
        filename = x[0];
        foreach(v; x[2].strip.splitter)
            flags |= size_t(1) << v.to!int;
    }
}

// a wrapper for an iopipe that writes data, and then releases the buffer
struct Writer(Chain)
{
    Chain chain;
    alias Char = ElementEncodingType!(WindowType!Chain);
    private AllocatedBuffer!(Char, Mallocator, 256) writeBuffer; // holds the data to be written, which must be parsed
    string[] keepSymbols; // holds macro identifiers that should be preserved
    bool recoverMode;
    void put(scope const(Char)[] data)
    {
        // We aren't going to release it, just build up enough space.
        immutable pos = writeBuffer.window.length;
        immutable need = pos + data.length;
        while(writeBuffer.window.length < need)
            enforce(writeBuffer.extend(need - writeBuffer.window.length) != 0);
        writeBuffer.window[pos .. pos + data.length] = data;
        writeBuffer.releaseBack(writeBuffer.window.length - need); // give excess back to the buffer
    }

    void write(Args...)(Args args)
    {
        import std.format;

        foreach(arg; args)
        {
            formattedWrite(this, "%s", arg);
        }
        releaseToOutput();
    }

    void writef(Args...)(string formatStr, Args args)
    {
        import std.format;
        formattedWrite(this, formatStr, args);
        releaseToOutput();
    }

    private void releaseToOutput()
    {
        while(writeBuffer.window.length > 0)
        {
            if(recoverMode)
            {
                // doesn't matter where it is, substitute the keep string for blank
                foreach(t; writeBuffer.window.splitter(symbolPostfix))
                {
                    while(t.length > 0)
                    {
                        if(chain.window.length == 0 && chain.extend(0) == 0)
                            assert(false, "Could not get more buffer data!");
                        immutable elems = min(chain.window.length, t.length);
                        chain.window[0 .. elems] = t[0 .. elems];
                        chain.release(elems);
                        t = t[elems .. $];
                    }
                }
                writeBuffer.releaseFront(writeBuffer.window.length);
            }
            else
            {
                size_t nToCopy = writeBuffer.window.length;
                string key = null;
                // check for a line that starts with #include. Those lines, we just ignore for replacements.
                if(!writeBuffer.window.strip.startsWith("#include"))
                {
                    foreach(k; keepSymbols)
                    {
                        import std.ascii; // c identifiers are in ASCII
                                          // if we can find the key in the input
                        auto searchwin = writeBuffer.window[0 .. nToCopy];
                        bool ident = false;
                        size_t matched;
                        size_t pos = searchwin.length;
                        foreach(i, c; searchwin)
                        {
                            if(isAlpha(c) || c == '_' || (ident && c >= '0' && c <= '9'))
                            {
                                ident = true;
                                if(matched != size_t.max && matched < k.length && k[matched] == c)
                                    ++matched;
                                else
                                    matched = size_t.max;
                            }
                            else if(matched == k.length)
                            {
                                // found the match
                                pos = i;
                                break;
                            }
                            else
                            {
                                ident = false;
                                matched = 0;
                            }
                        }

                        if(matched == k.length)
                        {
                            // matched. pos is set to character *after* the match.
                            key = k;
                            nToCopy = pos;
                        }
                    }
                }

                while(nToCopy > 0)
                {
                    if(!chain.window.length)
                    {
                        if(chain.extend(0) == 0)
                            assert(false, "Could not get more space to write data!");
                    }
                    import std.algorithm : min;
                    immutable elems = min(nToCopy, chain.window.length);
                    chain.window[0 .. elems] = writeBuffer.window[0 .. elems];
                    writeBuffer.releaseFront(elems);
                    nToCopy -= elems;
                    chain.release(elems);
                }

                if(key.length > 0)
                {
                    // we found a key that was output, output also the postfix
                    while(chain.window.length < symbolPostfix.length)
                        if(chain.extend(0) == 0)
                            assert(false, "could not get more space to write data!");
                    chain.window[0 .. symbolPostfix.length] = symbolPostfix;
                    chain.release(symbolPostfix.length);
                }
            }
        }
    }
}

auto writer(Chain)(Chain chain)
{
    return Writer!Chain(chain);
}

bool processInComment(const(char)[] line, bool inComment)
{
    while(line.length)
    {
        if(!inComment && line.startsWith("//"))
        {
            // rest of the line is a comment, but it doesn't last
            return false;
        }
        else if(!inComment && line.startsWith("/*"))
        {
            inComment = true;
            // skip the comment start
            line = line[2 .. $];
        }
        else if(inComment && line.startsWith("*/"))
        {
            line = line[2 .. $];
            inComment = false;
        }
        else
        {
            line.popFront;
        }
    }
    return inComment;
}

void usage(Option[] options)
{
    defaultGetoptPrinter("Usage: cpptool [options] file1.c [file2.c ...]", options);
}


int main(string[] args)
{
    import std.stdio : stderr;
    enum Mode
    {
        detect,
        preprocess,
        recover
    }
    static struct Opts
    {
        @description("Specify the mode for processing, detect = use source file to determine mode (default); preprocess = insert directive comments; recover = recover original directives")
        Mode mode = Mode.detect;

        @description("If code is trimmed, recover it from the original source file")
        bool recoverTrimmed = false;

        @description("Overwrite original files after preprocessing")
        bool overwrite = false;

        @description("List of identifiers that should be left alone instead of replaced")
        string[] ignored;
    }

    Opts opts;

    auto result = args.getopt2(opts);
    if(result.helpWanted)
    {
        usage(result.options);
        return 1;
    }

    auto files = args[1 .. $];
    if(files.length == 0)
    {
        stderr.writeln("Need files to process");
        usage(result.options);
        return 1;
    }

    // each file, we will process according to the options
    foreach(filename; files)
    {
        // build an iopipe of text lines
        auto lines = File(filename, mode!"r").refCounted
            .bufd // buffered
            .assumeText // assume it's utf8
            .byLine // extend one line at a time
            .segmentedPipe; // store lines in a buffer
        if(lines.extend(0) == 0)
        {
            stderr.writeln("Empty file! ", filename);
            continue;
        }
        auto ext = extension(filename);
        auto outfilename = filename[0 .. $-ext.length] ~ "_cpptool_tmp" ~ ext;
        auto outfile = bufd!char
            .push!(p => p.encodeText.outputPipe(File(outfilename, mode!"w").refCounted))
            .writer;
        with(Mode) final switch(opts.mode)
        {
            case detect:
                // TODO: make this work
                assert(false, "detect not implemented yet");
                /*if(lines.window.front.startsWith("//CPPTOOL")) // this isn't how it works...
                    // already processed, recover the original file
                    goto case recover;
                else
                    goto case preprocess;*/
            case preprocess:
                size_t codeID = 0;
                outfile.writef("//CPPTOOL %s\n", outfilename);
                outfile.keepSymbols = opts.ignored;
                bool inComment = false;
                while(!lines.window.empty)
                {
                    // process the next line
                    if(!inComment && lines.window.front.strip.startsWith("#"))
                    {
                        // search for the end of the segment
                        while(lines.window.back.endsWith("\\\n"))
                        {
                            if(lines.extend(0) == 0)
                                assert(false, "bad");
                        }
                        // all the current lines need to go into the file, with
                        // comments in front
                        outfile.writef("//>> %s ", codeID);
                        foreach(i, l; lines.window.enumerate)
                        {
                            if(i > 0)
                                outfile.write("\\+"); // continuation, these are removed by the preprocssor
                            outfile.write(l);
                        }

                        // now write the actual line(s)
                        foreach(l; lines.window)
                            outfile.write(l);

                        // now write the trailng comment
                        outfile.writef("//<< %s ", codeID);
                        foreach(i, l; lines.window.enumerate)
                        {
                            if(i > 0)
                                outfile.write("\\+"); // continuation, these are removed by the preprocssor
                            outfile.write(l);
                        }
                        lines.release(lines.window.length); // release all the lines processed
                        lines.extend(0);
                        ++codeID;
                    }
                    else
                    {
                        // not a preprocessor directive, just copy it
                        inComment = processInComment(lines.window.front, inComment);
                        outfile.write(lines.window.front);
                        lines.release(1);
                        lines.extend(0); // next line
                    }
                }
                break;
            case recover:
                outfile.recoverMode = true;
                // first, find the line that starts with `//CPPTOOL`
                while(lines.window.length > 0)
                {
                    if(lines.window.front.startsWith("//CPPTOOL"))
                    {
                        // found the beginning of the file
                        break;
                    }
                    lines.release(1);
                    lines.extend(0);
                }
                if(lines.window.length == 0)
                {
                    stderr.writeln("could not find rcovery header in file %s!", filename);
                    continue;
                }
                string mainfilename = lines.window.front["//CPPTOOL ".length .. $].strip.idup;
                stderr.writefln("found filename \"%s\"", mainfilename);
                // skip the line
                lines.release(1);

                // run the state machine
                bool inFile = true;
                bool inComment = false;  // true if /* has beeen detected
                size_t lastWrittenCodeID = size_t.max;
                while(lines.extend(0) != 0)
                {
                    auto line = lines.window.front;
                    if(!inComment && line.startsWith("#"))
                    {
                        // process the directive.
                        auto d = Directive(line);
                        if(d.flags & (FLAGS.beginFile | FLAGS.resumeFile))
                        {
                            // which file are we beginning/resuming
                            if(d.filename == mainfilename)
                                inFile = true;
                            else
                                inFile = false;
                        }
                    }
                    else if(lines.window.front.startsWith("//<<") ||
                            lines.window.front.startsWith("//>>"))
                    {
                        // this is a comment from cpptool about a preprocessor
                        // directive that was here. But we only want to restore it once.
                        line = line[5 .. $]; // skip header
                        auto codeID = line.parse!size_t;
                        if(lastWrittenCodeID != codeID)
                        {
                            lastWrittenCodeID = codeID;
                            // write the line, but split by \+
                            line = line[1 .. $]; // skip the space after the code id
                            foreach(i, l; line.splitter("\\+").enumerate)
                            {
                                if(i != 0)
                                    outfile.write("\\\n");
                                outfile.write(l);
                            }
                        }
                    }
                    else
                    {
                        // write the line only if we are in the main file
                        if(inFile)
                            outfile.writef("%s", line);
                        // determine if a comment is detected
                        inComment = processInComment(line, inComment);
                    }
                    // release all the lines just processed
                    lines.release(lines.window.length);
                }
                break;
        }
    }
    return 0;
}
