# Sets up the notebook boot environment: an environment with only PlutoRunner. This needs Pkg, which is why it is in a separate file: it is only included by Loader.jl when the boot environment needs to be created.
import Pkg

function pluto_boot_environment_setup(path)
    # Set up our notebook boot package environment by adding a single package:
    try
        Pkg.develop([Pkg.PackageSpec(; path)])
        # Pkg.develop([Pkg.PackageSpec(; path)]; io=devnull)
    catch
        @warn "Something went wrong while initializing the notebook boot environment... Trying again and showing you the output."
        Pkg.develop([Pkg.PackageSpec(; path)])
    end
    
    # Resolve
    try
        Pkg.resolve(; io=devnull) # supress IO
    catch
        @warn "Something went wrong while initializing the notebook boot environment... Trying again and showing you the output."
        try
            Pkg.resolve()
        catch e
            @error "Failed to resolve notebook boot environment" exception = (e, catch_backtrace())
        end
    end
    
    # Instantiate
    try
        # we don't suppress IO for this one because it can take very long, and that would be a frustrating experience without IO
        # precompilation switched off because of https://github.com/fonsp/Pluto.jl/issues/875
        Pkg.instantiate(; update_registry=false, allow_autoprecomp=false)
    catch e
        @error "Failed to instantiate notebook boot environment" exception = (e, catch_backtrace())
    end
end
