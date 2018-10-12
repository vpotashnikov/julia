# This file is a part of Julia. License is MIT: https://julialang.org/license

if !isempty(ARGS)
    ARGS[1] == "0" && exit(0)
end

# Prevent this from being put into the Main namespace
@eval Module() begin
if !isdefined(Base, :uv_eventloop)
    Base.reinit_stdio()
end
Base.include(@__MODULE__, joinpath(Sys.BINDIR, "..", "share", "julia", "test", "testhelpers", "FakePTYs.jl"))
import .FakePTYs: open_fake_pty

CTRL_C = '\x03'
UP_ARROW = "\e[A"
DOWN_ARROW = "\e[B"

precompile_script = """
2+2
print("")
@time 1+1
; pwd
? reinterpret
using Ra\t$CTRL_C
\\alpha\t$CTRL_C
\e[200~paste here ;)\e[201~"$CTRL_C
$UP_ARROW$DOWN_ARROW$CTRL_C
123\b\b\b$CTRL_C
\b\b$CTRL_C
f(x) = x03
f(1,2)
[][1]
cd("complet_path\t\t$CTRL_C
"""

using Base: julia_cmd
have_repl =  haskey(Base.loaded_modules,
                    Base.PkgId(Base.UUID("3fa0cd96-eef1-5676-8a61-b3b8758bbffb"), "REPL"))
Pkg = get(Base.loaded_modules,
          Base.PkgId(Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg"),
          nothing)

if Pkg !== nothing
    precompile_script *= Pkg.precompile_script
end

push!(LOAD_PATH, Sys.STDLIB)
using Sockets
Sockets.__init__()
using Libdl
empty!(LOAD_PATH)

function generate_precompile_statements()
    start_time = time()
    debug_output = devnull #stdout

    # Precompile a package
    mktempdir() do prec_path
        push!(DEPOT_PATH, prec_path)
        push!(LOAD_PATH, prec_path)
        pkgname = "__PackagePrecompilationStatementModule"
        mkpath(joinpath(prec_path, pkgname, "src"))
        write(joinpath(prec_path, pkgname, "src", "$pkgname.jl"),
              """
              module $pkgname
              end
              """)
        @eval using __PackagePrecompilationStatementModule
        empty!(LOAD_PATH)
        empty!(DEPOT_PATH)
    end

    print("Generating precompile statements...")
    mktemp() do precompile_file, precompile_file_h
        # Run a repl process and replay our script
        @static if Sys.iswindows()
            # Fake being cygwin
            pipename = """\\\\?\\pipe\\cygwin-$("0"^16)-pty10-abcdef"""
            server = listen(pipename)
            slave = connect(pipename)
            @assert ccall(:jl_ispty, Cint, (Ptr{Cvoid},), slave.handle) == 1
            master = accept(server)
        else
            slave, master = open_fake_pty()
            #pipe_fds = Ref((Cint(-1), Cint(-1)))
            #Base.uv_error("socketpair", ccall(:uv_socketpair, Cint, (Cint, Cint, Ptr{NTuple{2, Cint}}, Cint, Cint), 1, 0, pipe_fds, 0, 0))
            #slave = fdio(pipe_fds[][1], true)
            #master = fdio(pipe_fds[][2], true)
        end
        blackhole = Sys.isunix() ? "/dev/null" : "nul"
        if have_repl
            cmdargs = `--color=yes
                       -e 'import REPL; REPL.Terminals.is_precompiling[] = true'
                       `
        else
            cmdargs = `-e nothing`
        end
        p = withenv("JULIA_HISTORY" => blackhole,
                    "JULIA_PROJECT" => nothing, # remove from environment
                    "TERM" => "") do
            run(`$(julia_cmd()) -i -O0 --trace-compile=$precompile_file --startup-file=no $cmdargs`,
                slave, slave, slave; wait=false)
        end
        Base.close_pipe_sync(slave)
        # wait for the definitive prompt before start writing to the TTY
        write(debug_output, readuntil(master, "julia>", keep=true))
        write(debug_output, readavailable(master))
        # Prepare a background process to copy output from process until `slave` is closed
        output_copy = Base.BufferStream()
        tee = @async try
            while !eof(master)
                l = readavailable(master)
                write(debug_output, l)
                write(output_copy, l)
            end
        catch ex
            close(master)
            notify(got_prompt)
            if !(ex isa Base.IOError && ex.code == Base.UV_EIO)
                rethrow(ex) # ignore EIO on master after slave dies
            end
        end
        # Input our script
        if have_repl
            for l in split(precompile_script, '\n'; keepempty=false)
                sleep(0.1)
                # consume any other output
                bytesavailable(output_copy) > 0 && readavailable(output_copy)
                # push our input
                write(debug_output, "\n#### inputting statement: ####\n$(repr(l))\n####\n")
                write(master, l, "\n")
                readuntil(output_copy, "\n")
                # wait for the next prompt-like to appear
                # NOTE: this is rather innaccurate because the Pkg REPL mode is a special flower
                readuntil(output_copy, "\n")
                readuntil(output_copy, "> ")
            end
        end
        write(master, "exit()\n")
        wait(tee)
        success(p) || Base.pipeline_error(p)
        close(master)

        # Extract the precompile statements from stderr
        statements = Set{String}()
        for statement in eachline(precompile_file_h)
            occursin("Main.", statement) && continue
            push!(statements, statement)
        end

        if have_repl
            # Seems like a reasonable number right now, adjust as needed
            # comment out if debugging script
            @assert length(statements) > 700
        end

        # Create a staging area where all the loaded packages are available
        PrecompileStagingArea = Module()
        for (_pkgid, _mod) in Base.loaded_modules
            if !(_pkgid.name in ("Main", "Core", "Base"))
                eval(PrecompileStagingArea, :(const $(Symbol(_mod)) = $_mod))
            end
        end

        # Execute the collected precompile statements
        include_time = @elapsed for statement in sort(collect(statements))
            # println(statement)
            # Work around #28808
            occursin("\"YYYY-mm-dd\\THH:MM:SS\"", statement) && continue
            statement == "precompile(Tuple{typeof(Base.show), Base.IOContext{Base.TTY}, Type{Vararg{Any, N} where N}})" && continue
            try
                Base.include_string(PrecompileStagingArea, statement)
            catch
                @error "Failed to precompile $statement"
                rethrow()
            end
        end
        print(" $(length(statements)) generated in ")
        tot_time = time() - start_time
        Base.time_print(tot_time * 10^9)
        print(" (overhead "); Base.time_print((tot_time - include_time) * 10^9); println(")")
    end

    return
end

generate_precompile_statements()

end # @eval
