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
    void put(scope const(Char)[] data)
    {
        while(data.length > 0)
        {
            if(!chain.window.length)
            {
                if(chain.extend(0) == 0)
                    assert(false, "Could not get more space to write data!");
            }
            import std.algorithm : min;
            immutable elems = min(data.length, chain.window.length);
            chain.window[0 .. elems] = data[0 .. elems];
            data = data[elems .. $];
            chain.release(elems); // lock in data to the write pipe
        }
    }

    void write(Args...)(Args args)
    {
        import std.format;

        foreach(arg; args)
        {
            formattedWrite(this, "%s", arg);
        }
    }

    void writef(Args...)(string formatStr, Args args)
    {
        import std.format;
        formattedWrite(this, formatStr, args);
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
                while(!lines.window.empty)
                {
                    // process the next line
                    if(lines.window.front.strip.startsWith("#"))
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
                        outfile.write(lines.window.front);
                        lines.release(1);
                        lines.extend(0); // next line
                    }
                }
                break;
            case recover:
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
                bool inFile = false;
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
