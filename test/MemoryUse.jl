using Test
import Pluto
import Pluto: update_save_run!, WorkspaceManager, ClientSession, ServerSession, Notebook, Cell, SessionActions, PlutoRunner
using Pluto.WorkspaceManager: poll
import Malt

# https://github.com/JuliaLang/julia/issues/39270 (the other tests that start and stop processes do this too)
windows_workaround() = Sys.iswindows() && sleep(.5)

# These tests make sure that closing a notebook gives its memory back. A notebook can be big (its outputs can be megabytes each), and a long-running Pluto server opens and closes many notebooks.

"Run the garbage collector until `ref` is cleared. Returns whether it was cleared."
function is_collected(ref::WeakRef)
    poll(10.0, 0.1) do
        GC.gc(true)
        ref.value === nothing
    end
end

# Everything that refers to the notebook is created inside of this function, so that the test itself does not keep the notebook alive through a stale reference on the stack.
@noinline function open_use_and_shutdown(🍭::ServerSession; with_client::Bool=true)
    notebook = Notebook([
        Cell("md\"# Hello *world*\""),
        Cell("""
        begin
            struct BigHTML; n::Int; end
            Base.show(io::IO, ::MIME"text/html", b::BigHTML) = print(io, "<div>", "x"^b.n, "</div>")
        end
        """),
        Cell("BigHTML(1_000_000)"),
    ], tempname() * ".jl")
    🍭.notebooks[notebook.notebook_id] = notebook

    windows_workaround()
    update_save_run!(🍭, notebook, notebook.cells)
    @assert all(c -> !c.errored, notebook.cells) [c.output.body for c in notebook.cells]

    client = nothing
    if with_client
        client = ClientSession(Symbol("memorytest_", notebook.notebook_id), devnull)
        client.connected_notebook = notebook
        🍭.connected_clients[client.id] = client
        Pluto.send_notebook_changes!(Pluto.ClientRequest(; session=🍭, notebook, initiator=Pluto.Initiator(client, :test)))
    end

    refs = (
        notebook=WeakRef(notebook),
        cell=WeakRef(notebook.cells[3]),
        output=WeakRef(notebook.cells[3].output.body),
        client=client === nothing ? nothing : WeakRef(client),
    )
    @assert length(refs.output.value) >= 1_000_000

    windows_workaround()
    SessionActions.shutdown(🍭, notebook)
    windows_workaround()
    with_client && @test Pluto.disconnect_client!(🍭, client.id)
    refs
end

@noinline function prerender_and_shutdown(🍭::ServerSession)
    # `waiting_for_permission` is the mode where only the text cells run, in the offline renderer (in this process), and no notebook process or package environment is started.
    notebook = Notebook([Cell("md\"Hello *world*\""), Cell("html\"<b>bold</b>\"")], tempname() * ".jl")
    notebook.process_status = Pluto.ProcessStatus.waiting_for_permission
    🍭.notebooks[notebook.notebook_id] = notebook

    update_save_run!(🍭, notebook, notebook.cells; prerender_text=true)

    @test occursin("world", notebook.cells[1].output.body)
    @test occursin("bold", notebook.cells[2].output.body)
    for cell in notebook.cells
        id = cell.cell_id
        @test !haskey(PlutoRunner.cell_results, id)
        @test !haskey(PlutoRunner.cell_runtimes, id)
        @test !haskey(PlutoRunner.cell_published_objects, id)
        @test !haskey(PlutoRunner.cell_expanded_exprs, id)
        @test !haskey(PlutoRunner.pluto_cell_loggers, id)
        @test !haskey(PlutoRunner.cell_js_links, id)
    end
    @test !haskey(PlutoRunner.pluto_log_channels, notebook.notebook_id)

    ref = WeakRef(notebook)
    SessionActions.shutdown(🍭, notebook)
    ref
end

@noinline function start_worker(🍭::ServerSession, notebook::Notebook)
    windows_workaround()
    update_save_run!(🍭, notebook, notebook.cells)
    WeakRef(WorkspaceManager.get_workspace((🍭, notebook)).worker)
end

@testset "Memory use" begin

    @testset "Closed notebook is garbage collected ($mode)" for mode in (:own_process, :in_process)
        🍭 = ServerSession()
        🍭.options.evaluation.workspace_use_distributed = mode === :own_process

        # Open and close twice: the second time runs with a warm session.
        for _ in 1:2
            refs = open_use_and_shutdown(🍭)

            @test is_collected(refs.notebook)
            @test is_collected(refs.cell)
            @test is_collected(refs.output)
            @test is_collected(refs.client)
        end
        @test isempty(🍭.notebooks)
        @test isempty(🍭.connected_clients)
        # The shared caches should not keep a closed notebook alive either.
        @test isempty(Pluto._cache_for_topological_order)
    end

    @testset "State of a disconnected client is forgotten" begin
        🍭 = ServerSession()
        🍭.options.evaluation.workspace_use_distributed = false

        notebook = Notebook([Cell("1 + 1")], tempname() * ".jl")
        🍭.notebooks[notebook.notebook_id] = notebook
        update_save_run!(🍭, notebook, notebook.cells)

        client = ClientSession(:memorytest_client, devnull)
        client.connected_notebook = notebook
        🍭.connected_clients[client.id] = client
        Pluto.send_notebook_changes!(Pluto.ClientRequest(; session=🍭, notebook, initiator=Pluto.Initiator(client, :test)))
        @test haskey(Pluto.current_state_for_clients, client)

        @test Pluto.disconnect_client!(🍭, client.id)
        @test !haskey(🍭.connected_clients, client.id)
        @test !haskey(Pluto.current_state_for_clients, client)
        @test !Pluto.disconnect_client!(🍭, client.id) # already gone

        SessionActions.shutdown(🍭, notebook)
    end

    @testset "Prerendering text cells leaves nothing behind" begin
        🍭 = ServerSession()
        ref = prerender_and_shutdown(🍭)
        @test is_collected(ref)
    end

    @testset "PlutoRunner.forget_cells!" begin
        a, b = Base.UUID(1), Base.UUID(2)
        for id in (a, b)
            PlutoRunner.cell_results[id] = 1
            PlutoRunner.cell_runtimes[id] = nothing
            PlutoRunner.cell_published_objects[id] = Dict{String,Any}()
            PlutoRunner.cell_registered_bond_names[id] = Set{Symbol}()
            PlutoRunner.tree_display_extra_items[id] = Dict{PlutoRunner.ObjectDimPair,Int64}()
            PlutoRunner.cell_js_links[id] = Dict{String,PlutoRunner.JSLink}()
        end

        PlutoRunner.forget_cells!([a])
        for field in (:cell_results, :cell_runtimes, :cell_published_objects, :cell_registered_bond_names, :tree_display_extra_items, :cell_js_links)
            d = getfield(PlutoRunner, field)
            @test !haskey(d, a)
            @test haskey(d, b)
        end

        PlutoRunner.forget_cells!([b])
        PlutoRunner.forget_cells!([b]) # forgetting twice is fine
    end

    @testset "Notebook process is released after it is stopped" begin
        🍭 = ServerSession()
        🍭.options.evaluation.workspace_use_distributed = true
        notebook = Notebook([Cell("1 + 1")], tempname() * ".jl")
        🍭.notebooks[notebook.notebook_id] = notebook

        n_procs = length(Malt.__iNtErNaL_get_running_procs())
        worker_ref = start_worker(🍭, notebook)
        @test length(Malt.__iNtErNaL_get_running_procs()) == n_procs + 1

        windows_workaround()
        WorkspaceManager.unmake_workspace((🍭, notebook))
        windows_workaround()
        @test length(Malt.__iNtErNaL_get_running_procs()) == n_procs

        if WorkspaceManager.MALT_CAN_SKIP_STDIO_RELAY
            # Malt keeps a stopped worker in memory (its sockets, buffers, ...) forever, unless we clean up after it.
            @test is_collected(worker_ref)
        else
            @info "This version of Malt cannot be cleaned up completely: skipped some tests."
        end
        delete!(🍭.notebooks, notebook.notebook_id)
    end

    @testset "Notebook process does not load Pkg" begin
        # `Pkg` is big (about 80 MB in every notebook process, on Julia 1.12 and 1.13), and we don't need it in the notebook process: precompiling the packages of the notebook can be done with `Base.Precompilation`.
        🍭 = ServerSession()
        🍭.options.evaluation.workspace_use_distributed = true
        notebook = Notebook([Cell("1 + 1")], tempname() * ".jl")
        🍭.notebooks[notebook.notebook_id] = notebook

        windows_workaround()
        # (this also runs the package manager of the notebook, including the precompile step that runs in the notebook process)
        update_save_run!(🍭, notebook, notebook.cells)
        @test notebook.cells[1].output.body == "2"

        ws = WorkspaceManager.get_workspace((🍭, notebook))
        pkg_loaded = Malt.remote_eval_fetch(ws.worker, :(haskey(Base.loaded_modules, Base.PkgId(Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg"))))
        if isdefined(Base, :Precompilation)
            @test !pkg_loaded
        else
            @info "On this version of Julia, `Pkg` is needed to precompile, so it was not tested whether it is loaded."
        end

        windows_workaround()
        SessionActions.shutdown(🍭, notebook)
    end

    @testset "The notebook boot environment is created if it does not exist" begin
        # The first time that a notebook process starts, an environment with `PlutoRunner` is created. This needs `Pkg`, which `Loader.jl` loads only for this.
        old_path = Pluto.pluto_boot_environment_path[]
        mktempdir() do dir
            Pluto.pluto_boot_environment_path[] = dir
            try
                🍭 = ServerSession()
                🍭.options.evaluation.workspace_use_distributed = true
                notebook = Notebook([Cell("x = 1 + 1"), Cell("PlutoRunner.notebook_id[] isa Base.UUID")], tempname() * ".jl")
                🍭.notebooks[notebook.notebook_id] = notebook

                windows_workaround()
                update_save_run!(🍭, notebook, notebook.cells)
                @test notebook.cells[1].output.body == "2"
                @test notebook.cells[2].output.body == "true"

                created = readdir(dir; join=true)
                @test length(created) == 1
                @test isfile(joinpath(only(created), "Project.toml"))
                @test isfile(joinpath(only(created), "Manifest.toml"))

                windows_workaround()
                SessionActions.shutdown(🍭, notebook)
            finally
                Pluto.pluto_boot_environment_path[] = old_path
            end
        end
    end

    @testset "Failed startup of a notebook process does not leave a process running" begin
        🍭 = ServerSession()
        🍭.options.evaluation.workspace_use_distributed = true
        🍭.options.evaluation.workspace_custom_startup_expr = "error(\"this notebook process cannot start\")"
        notebook = Notebook([Cell("1 + 1")], tempname() * ".jl")

        n_procs = length(Malt.__iNtErNaL_get_running_procs())
        windows_workaround()
        @test_throws Exception WorkspaceManager.make_workspace((🍭, notebook))
        # (The process is stopped in the background.)
        @test poll(() -> length(Malt.__iNtErNaL_get_running_procs()) == n_procs, 60.0, 0.1)
    end

    @testset "Re-running a cell frees its previous result first" begin
        🍭 = ServerSession()
        🍭.options.evaluation.workspace_use_distributed = true

        N = 2 * 10^7 # 160 MB
        # The cell remembers how much memory is in use right before it allocates its new array.
        code(i) = "x = (GC.gc(); GC.gc(); global LIVE_BEFORE_ALLOCATING = Base.gc_live_bytes(); rand($N)) # run $(i)"
        notebook = Notebook([Cell(code(1)), Cell("length(x)")], tempname() * ".jl")
        🍭.notebooks[notebook.notebook_id] = notebook

        windows_workaround()
        update_save_run!(🍭, notebook, notebook.cells)
        @test notebook.cells[2].output.body == string(N)

        notebook.cells[1].code = code(2)
        update_save_run!(🍭, notebook, notebook.cells[1:1])
        @test notebook.cells[2].output.body == string(N)

        live_before = WorkspaceManager.eval_fetch_in_workspace((🍭, notebook), :LIVE_BEFORE_ALLOCATING)
        # Without cleanup, the 160 MB array from the first run is still in memory.
        @test live_before < N * 8 / 2

        windows_workaround()
        SessionActions.shutdown(🍭, notebook)
    end

end
