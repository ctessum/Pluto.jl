
"These expressions get evaluated inside every newly create module inside a `Workspace`."
const workspace_preamble = [
    :(using Main.PlutoRunner, Main.PlutoRunner.Markdown, Main.PlutoRunner.InteractiveUtils),
    :(show, showable, showerror, repr, string, print, println), # https://github.com/JuliaLang/julia/issues/18181
]

const PLUTO_INNER_MODULE_NAME = Symbol("#___this_pluto_module_name")

const moduleworkspace_count = Ref(0)
function increment_current_module()::Symbol
    id = (moduleworkspace_count[] += 1)
    new_workspace_name = Symbol("workspace#", id)

    Core.eval(Main, :(
        module $(new_workspace_name)
            $(workspace_preamble...)
            const $(PLUTO_INNER_MODULE_NAME) = $(new_workspace_name)
        end
    ))

    new_workspace_name
end

"""
Precompile all packages in the active environment (the notebook environment), writing progress to `io`.

This is what `Pkg.precompile(; already_instantiated=true)` does. On recent Julia versions, that is a thin wrapper around `Base.Precompilation.precompilepkgs`, which we can call directly. That way, the (large) `Pkg` standard library does not need to be loaded into every notebook process, which saves about 80 MB per notebook.
"""
function precompile_notebook_environment(io::IO)
    if isdefined(Base, :Precompilation) && hasmethod(Base.Precompilation.precompilepkgs, Tuple{Vector{String}}, (:io,))
        Base.Precompilation.precompilepkgs(String[]; io)
    else
        Pkg = Base.require(Base.PkgId(Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg"))
        Base.invokelatest(Pkg.precompile; already_instantiated=true, io)
    end
end
