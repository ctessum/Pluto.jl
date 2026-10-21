# The goal of this file is to import PlutoRunner into Main, on the process of the notebook (created by Malt.jl).
# 
# This is difficult because PlutoRunner uses standard libraries and packages that are not necessarily available in the standard environment. 
# 
# Our solution is to create a temporary environment just for loading PlutoRunner. This environment is stored in a scratchspace parameterized by the Pluto version and julia version,
# and used by all notebook launches. Reusing the environment means extra speed.


begin
    local original_LP = copy(LOAD_PATH)
    local original_AP = Base.ACTIVE_PROJECT[]

    # Path to our notebook boot package environment which is set by WorkspaceManager
    # when spawning the process.
    local runner_env_dir = pluto_boot_environment_path

    local new_LP = ["@", "@stdlib"]
    local new_AP = runner_env_dir

    try
        # Activate the environment
        copy!(LOAD_PATH, new_LP)
        Base.ACTIVE_PROJECT[] = new_AP
        
        function setup()
            # Pkg is a big package, and this setup is only needed once, so it lives in a separate file that imports Pkg, which we only load when needed. (Most notebook processes never need Pkg.)
            Base.include(Main, joinpath(@__DIR__, "BootSetup.jl"))
            Base.invokelatest(Main.pluto_boot_environment_setup, joinpath(@__DIR__, "PlutoRunner"))
        end

        if !isfile(joinpath(new_AP, "Project.toml")) || !isfile(joinpath(new_AP, "Manifest.toml"))
            setup()
        end

        try
            # Import PlutoRunner into Main
            # try the first time without setup
            # This might trigger precompilation, which is actually what we want.
            import PlutoRunner
        catch
            # this means that setup is needed.
            setup()
            import PlutoRunner
        end
    finally
        # Reset the pkg environment
        copy!(LOAD_PATH, original_LP)
        Base.ACTIVE_PROJECT[] = original_AP
    end
end
