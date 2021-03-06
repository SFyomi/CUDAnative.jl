# code reflection entry-points

using InteractiveUtils

# Return the capability of the current context's device, or a sane fall-back.
function current_capability()
    fallback = minimum(target_support)
    if !initialized[]
        return fallback
    end

    ctx = CuCurrentContext()
    if ctx == nothing
        return fallback
    end

    return capability(device(ctx))
end


#
# code_* replacements
#

"""
    code_llvm([io], f, types; optimize=true, dump_module=false, cap::VersionNumber)

Prints the device LLVM IR generated for the method matching the given generic function and
type signature to `io` which defaults to `stdout`. The IR is optimized according to
`optimize` (defaults to true), and the entire module, including headers and other functions,
is dumped if `dump_module` is set (defaults to false). The device capability `cap` to
generate code for defaults to the current active device's capability, or v"2.0" if there is
no such active context.

See also: [`@device_code_llvm`](@ref), [`Base.code_llvm`](@ref)
"""
function code_llvm(io::IO, @nospecialize(func::Core.Function), @nospecialize(types=Tuple);
                   optimize::Bool=true, dump_module::Bool=false,
                   cap::VersionNumber=current_capability(), kernel::Bool=false, kwargs...)
    tt = Base.to_tuple_type(types)
    check_invocation(func, tt; kernel=kernel)

    mod, entry = irgen(func, tt)
    if kernel
        entry = promote_kernel!(mod, entry, tt; kwargs...)
    end
    if optimize
        optimize!(mod, entry, cap)
    end
    if dump_module
        show(io, mod)
    else
        show(io, entry)
    end
end
code_llvm(@nospecialize(func), @nospecialize(types=Tuple); kwargs...) = code_llvm(stdout, func, types; kwargs...)

"""
    code_ptx([io], f, types; cap::VersionNumber, kernel::Bool=false)

Prints the PTX assembly generated for the method matching the given generic function and
type signature to `io` which defaults to `stdout`. The device capability `cap` to generate
code for defaults to the current active device's capability, or v"2.0" if there is no such
active context. The optional `kernel` parameter indicates whether the function in question
is an entry-point function, or a regular device function.

See also: [`@device_code_ptx`](@ref)
"""
function code_ptx(io::IO, @nospecialize(func::Core.Function), @nospecialize(types=Tuple);
                  cap::VersionNumber=current_capability(), kernel::Bool=false, kwargs...)
    tt = Base.to_tuple_type(types)
    check_invocation(func, tt; kernel=kernel)

    ptx,_ = compile_function(func, tt, cap; kernel=kernel, kwargs...)
    # TODO: this code contains all the functions in the call chain,
    #       is it possible to implement `dump_module`?
    print(io, ptx)
end
code_ptx(@nospecialize(func), @nospecialize(types=Tuple); kwargs...) =
    code_ptx(stdout, func, types; kwargs...)

"""
    code_sass([io], f, types, cap::VersionNumber)

Prints the SASS code generated for the method matching the given generic function and type
signature to `io` which defaults to `stdout`. The device capability `cap` to generate code
for defaults to the current active device's capability, or v"2.0" if there is no such active
context. The method needs to be a valid entry-point kernel, eg. it should not return any
values.

See also: [`@device_code_sass`](@ref)
"""
function code_sass(io::IO, @nospecialize(func::Core.Function), @nospecialize(types=Tuple);
                   cap::VersionNumber=current_capability(), kernel::Bool=true, kwargs...)
    if !kernel
        error("Can only generate SASS code for kernel functions")
    end
    if ptxas === nothing || cuobjdump === nothing
        error("Your CUDA installation does not provide ptxas or cuobjdump, both of which are required for code_sass")
    end

    tt = Base.to_tuple_type(types)
    check_invocation(func, tt; kernel=kernel)

    ptx,_ = compile_function(func, tt, cap; kwargs...)

    fn = tempname()
    gpu = "sm_$(cap.major)$(cap.minor)"
    # NOTE: this might not match what is being executed, due to the PTX->SASS conversion
    #       by the driver possibly not matching what `ptxas` (part of the toolkit) does.
    # TODO: see how `nvvp` extracts SASS code when doing PC sampling, and copy that.
    Base.run(`$ptxas --gpu-name $gpu --output-file $fn --input-as-string $ptx`)
    try
        print(io, read(`$cuobjdump --dump-sass $fn`, String))
    finally
        rm(fn)
    end
end
code_sass(@nospecialize(func), @nospecialize(types=Tuple); kwargs...) =
    code_sass(stdout, func, types; kwargs...)


#
# @device_code_* functions
#

export @device_code_lowered, @device_code_typed, @device_code_warntype,
       @device_code_llvm, @device_code_ptx, @device_code_sass

function emit_hooked_compilation(inner_hook, ex...)
    user_code = ex[end]
    user_kwargs = ex[1:end-1]
    quote
        # wipe the compile cache to force recompilation
        empty!(CUDAnative.compilecache)

        local kernels = 0
        function outer_hook(args...; kwargs...)
            kernels += 1
            $inner_hook(args...; $(map(esc, user_kwargs)...), kwargs...)
        end

        if CUDAnative.compile_hook[] != nothing
            error("Chaining multiple @device_code calls is unsupported")
        end
        try
            CUDAnative.compile_hook[] = outer_hook
            $(esc(user_code))
        finally
            CUDAnative.compile_hook[] = nothing
        end

        if kernels == 0
            error("no kernels executed while evaluating the given expression")
        end

        nothing
    end
end

# NOTE: these hooks take both a `f` and an inner `f`, because of how `@cuda`/`_cuda` work:
#       kernels are automatically wrapper in a function returning nothing, for usability.
#
#       Julia-level reflection (lowered/typed/warntype) skips these wrapper, because we
#       can't do call-site inlining and the kernel wrapper would hide any meaningful code.
#
#       at the LLVM level, we inline everything so there's no need to hide the wrapper.

"""
    @device_code_lowered ex

Evaluates the expression `ex` and returns the result of [`Base.code_lowered`](@ref) for
every compiled CUDA kernel.

See also: [`Base.@code_lowered`](@ref)
"""
macro device_code_lowered(ex...)
    quote
        buf = Any[]
        function hook(f, inner_f, tt, cap)
            if inner_f != nothing
                f = inner_f
            end
            append!(buf, code_lowered(f, tt))
        end
        $(emit_hooked_compilation(:hook, ex...))
        buf
    end
end

"""
    @device_code_typed ex

Evaluates the expression `ex` and returns the result of [`Base.code_typed`](@ref) for
every compiled CUDA kernel.

See also: [`Base.@code_typed`](@ref)
"""
macro device_code_typed(ex...)
    quote
        buf = Any[]
        function hook(f, inner_f, tt, cap)
            if inner_f != nothing
                f = inner_f
            end
            append!(buf, code_typed(f, tt))
        end
        $(emit_hooked_compilation(:hook, ex...))
        buf
    end
end

"""
    @device_code_warntype [io::IO=stdout] ex

Evaluates the expression `ex` and prints the result of [`Base.code_warntype`](@ref) to `io`
for every compiled CUDA kernel.

See also: [`Base.@code_warntype`](@ref)
"""
macro device_code_warntype(ex...)
    function hook(f, inner_f, tt, cap; io::IO=stdout)
        if inner_f != nothing
            f = inner_f
        end
        code_warntype(io, f, tt)
    end
    emit_hooked_compilation(hook, ex...)
end

"""
    @device_code_llvm [io::IO=stdout, ...] ex

Evaluates the expression `ex` and prints the result of [`Base.code_llvm`](@ref) to `io` for
every compiled CUDA kernel. For other supported keywords, see
[`CUDAnative.code_llvm`](@ref).

See also: [`Base.@code_llvm`](@ref)
"""
macro device_code_llvm(ex...)
    function hook(f, inner_f, tt, cap; io::IO=stdout, kwargs...)
        code_llvm(io, f, tt; kernel=true, cap=cap, kwargs...)
    end
    emit_hooked_compilation(hook, ex...)
end

"""
    @device_code_ptx [io::IO=stdout, ...] ex

Evaluates the expression `ex` and prints the result of [`CUDAnative.code_ptx`](@ref) to `io`
for every compiled CUDA kernel. For other supported keywords, see
[`CUDAnative.code_ptx`](@ref).
"""
macro device_code_ptx(ex...)
    function hook(f, inner_f, tt, cap; io::IO=stdout, kwargs...)
        code_ptx(io, f, tt; kernel=true, cap=cap, kwargs...)
    end
    emit_hooked_compilation(hook, ex...)
end

"""
    @device_code_sass [io::IO=stdout, ...] ex

Evaluates the expression `ex` and prints the result of [`CUDAnative.code_sass`](@ref) to
`io` for every compiled CUDA kernel. For other supported keywords, see
[`CUDAnative.code_sass`](@ref).
"""
macro device_code_sass(ex...)
    function hook(f, inner_f, tt, cap; io::IO=stdout, kwargs...)
        # we have inlined every function using LLVM, so don't hide the kernel wrapper.
        code_sass(io, f, tt; cap=cap, kwargs...)
    end
    emit_hooked_compilation(hook, ex...)
end
