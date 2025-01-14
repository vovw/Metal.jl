# Not necessary, but removes some errors that don't seem to affect the output
using Clang_jll
Clang_jll.libclang = "/Applications/Xcode.app/Contents/Frameworks/libclang.dylib"

using Clang.Generators
using Clang
using Glob
using JLD2
using JuliaFormatter
using Logging

# Use system SDK
SDK_PATH = `xcrun --show-sdk-path` |> open |> readchomp |> String

main(name::AbstractString; kwargs...) = main([name]; kwargs...)
function main(names::AbstractVector=["all"]; sdk_path=SDK_PATH)
    path_to_framework(framework) = joinpath(sdk_path, "System/Library/Frameworks/",framework*".framework","Headers")
    path_to_mps_framework(framework) = joinpath(sdk_path, "System/Library/Frameworks/","MetalPerformanceShaders.framework","Frameworks",framework*".framework","Headers")

    defines = []

    ctxs = []

    if "all" in names || "libmtl" in names || "mtl" in names
        fwpath = path_to_framework("Metal")
        tctx = wrap("libmtl", joinpath(fwpath, "Metal.h"); defines)
        push!(ctxs, tctx)
    end

    if "all" in names || "libmps" in names || "mps" in names
        mpsframeworks = ["MPSCore", "MPSImage", "MPSMatrix", "MPSNDArray", "MPSNeuralNetwork", "MPSRayIntersector"]
        fwpaths = [path_to_framework("MetalPerformanceShaders")]
        fwpaths = append!(fwpaths, path_to_mps_framework.(mpsframeworks))

        getheaderfname(path) = Sys.splitext(Sys.splitpath(path)[end-1])[1] * ".h"
        headers = joinpath.(fwpaths, getheaderfname.(fwpaths))

        tctx = wrap("libmps", headers; defines)
        push!(ctxs, tctx)
    end

    return ctxs
end

function wrap(name, headers; defines=[])
    @info "Wrapping $name"

    options = load_options(joinpath(@__DIR__, "$(name).toml"))

    args = [
        "-x","objective-c",
        "-isysroot", SDK_PATH,
        "-fblocks",
        "-fregister-global-dtors-with-atexit",
        "-fgnuc-version=4.2.1",
        "-fobjc-runtime=macosx-15.0.0",
        "-fobjc-exceptions",
        "-fexceptions",
        "-fmax-type-align=16",
        "-fcommon",
        "-DNS_FORMAT_ARGUMENT(A)=",
        "-D__GCC_HAVE_DWARF2_CFI_ASM=1",
        ]

    for define in defines
        if isa(define, Pair)
            append!(args, ["-D", "$(first(define))=$(last(define))"])
        else
            append!(args, ["-D", "$define"])
        end
    end

    @info "Creating context"
    ctx = create_objc_context(headers, args, options)

    @info "Building no printing"
    build!(ctx, BUILDSTAGE_NO_PRINTING)

    rewriter!(ctx, options)

    @info "Building only printing"
    build!(ctx, BUILDSTAGE_PRINTING_ONLY)

    output_file = options["general"]["output_file_path"]

    # prepend "autogenerated, do not edit!" comment
    output_data = read(output_file, String)
    open(output_file, "w") do io
        println(io, """# This file is automatically generated. Do not edit!
                       # To re-generate, execute res/wrap/wrap.jl""")
        println(io)
        print(io, output_data)
    end

    format_file(output_file, YASStyle())

    return ctx
end

# Uses the same passes as with C, but with some other changes
create_objc_context(header::AbstractString, args=String[], ops=Dict()) = create_objc_context([header], args, ops)
function create_objc_context(headers::Vector, args::Vector=String[], options::Dict=Dict())
    system_dirs = [
                    SDK_PATH,
                    "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain"
                  ]

    regen = if haskey(options, "general") && haskey(options["general"], "regenerate_dependent_headers")
        options["general"]["regenerate_dependent_headers"]
    else
        false
    end

    # Since the framework we're wrapping is a system header,
    # find all dependent headers, then remove all but the relevant ones
    # also temporarily disable logging
    dep_headers_fname = if haskey(options, "general") && haskey(options["general"], "library_name")
        splitext(splitpath(options["general"]["output_file_path"])[end])[1]*".JLD2"
    else
        nothing
    end
    Base.CoreLogging._min_enabled_level[] = Logging.Info+1
    dependent_headers = if !regen && !isnothing(dep_headers_fname) && isfile(dep_headers_fname)
        JLD2.load(dep_headers_fname, "dep_headers")
    else
        all_headers = find_dependent_headers(headers,args,[])
        dep_headers = Vector{eltype(all_headers)}(undef, 0)
        for header in headers
            target_framework = "/"*joinpath(Sys.splitpath(header)[end-2:end-1])
            dep_headers = append!(dep_headers, filter(s -> occursin(target_framework, s), all_headers))
        end
        if haskey(options, "general") && haskey(options["general"], "extra_target_headers")
            append!(dep_headers, options["general"]["extra_target_headers"])
        end
        regen || JLD2.@save dep_headers_fname dep_headers
        dep_headers
    end
    Base.CoreLogging._min_enabled_level[] = Logging.Debug

    ctx = Context(; options)

    @info "Parsing headers..."
    parse_headers!(ctx, headers, args)

    Generators.add_default_passes!(ctx, options, system_dirs, dependent_headers)
end

function rewriter!(ctx, options)
    if haskey(options, "api")
        for node in get_nodes(ctx.dag)
            if typeof(node) <: Generators.ExprNode{<:Generators.AbstractStructNodeType}
                expr = node.exprs[1]
                structName = String(expr.args[2])

                if haskey(options["api"], structName)
                    # Add default constructer to some structs
                    if haskey(options["api"][structName], "constructor")
                        expr = node.exprs[1]
                        con = options["api"][structName]["constructor"] |> Meta.parse

                        if con.head == :(=) && con.args[2] isa Expr && con.args[2].head == :block &&
                            con.args[2].args[1] isa LineNumberNode && con.args[2].args[2].head == :call
                            con.args[2] = con.args[2].args[2]
                        end
                        push!(expr.args[3].args, con)
                    end
                end
            end
        end
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
