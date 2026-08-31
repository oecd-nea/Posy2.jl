using Documenter
using Posy2
using Nosy

DocMeta.setdocmeta!(
    Posy2,
    :DocTestSetup,
    :(using Posy2, Nosy),
    recursive=true,
)

doctest_setting = get(ENV, "DOCUMENTER_DOCTEST", "true")
doctest_value = doctest_setting == "fix" ? :fix : parse(Bool, doctest_setting)

branch = get(ENV, "GITHUB_REF_NAME", "main")
is_tag = get(ENV, "GITHUB_REF_TYPE", "branch") == "tag"

docs_version = is_tag ? "stable" : branch
edit_branch = is_tag ? nothing : branch

makedocs(
    modules=[Posy2],
    sitename="Posy2.jl",
    authors="Guillaume KRIVTCHIK, OECD Nuclear Energy Agency, and contributors",
    repo="https://github.com/oecd-nea/Posy2.jl/blob/{commit}{path}#L{line}",
    format=Documenter.HTML(
        prettyurls=get(ENV, "CI", "false") == "true",
        canonical="https://oecd-nea.github.io/Posy2.jl/$(docs_version)/",
        repolink="https://github.com/oecd-nea/Posy2.jl",
        assets=String[],
        edit_link=edit_branch,
    ),
    pages=[
        "Home" => "index.md",
        "Getting Started" => "getting-started.md",
        "Modelling Concepts" => [
            "Overview" => "concepts.md",
            "Study Configuration" => "concepts/options.md",
            "Input Workbooks" => "concepts/input-data.md",
            "Building a Snapshot" => "concepts/building-snapshot.md",
            "Component Builders" => [
                "Overview" => "components.md",
                "Demand and Flexibility" => "components/demand.md",
                "Generation" => "components/generation.md",
                "Storage" => "components/storage-conversion.md",
                "Electric Vehicles" => "components/electric-vehicles.md",
                "Interconnections" => "components/interconnections.md",
                "Hydrogen" => "components/hydrogen.md",
            ],
            "Extending Posy2" => "concepts/extending.md",
            "Optimizing a Snapshot" => "concepts/optimizing.md",
            "Querying a Snapshot" => "concepts/querying.md",
            "Tags and Post-Processing" => "concepts/tags.md",
            "Exporting Results" => "concepts/exporting.md",
        ],
        "Performance" => "performance.md",
        "Examples" => [
            "Overview" => "examples.md",
            "One Country" => "examples/one-country.md",
            "Dispatchable Generation" => "examples/dispatchable-generation.md",
            "Dispatch Optimization" => "examples/dispatch-optimization.md",
            "CO2 Pricing" => "examples/co2-pricing.md",
            "Nuclear" => "examples/nuclear.md",
            "Battery Storage" => "examples/battery-storage.md",
            "Pumped Storage" => "examples/pumped-storage-hydro.md",
            "Hydro Reservoir" => "examples/hydro-reservoir.md",
            "Demand Response" => "examples/demand-response.md",
            "Electric Vehicles" => "examples/electric-vehicles.md",
            "Hydrogen Production" => "examples/hydrogen-production.md",
            "Two Countries" => "examples/two-countries.md",
            "Price Interconnection" => "examples/price-interconnection.md",
            "DC OPF" => "examples/dc-opf.md",
            "Stochastic Programming" => "examples/stochastic.md",
            "Coarse Time Mesh" => "examples/coarse-time-mesh.md",
            "Infeasibility" => "examples/infeasibility.md",
        ],
        "API Reference" => "api.md",
    ],
    doctest=doctest_value,
    doctestfilters=[
        r"([+-]?\d+\.\d{6})\d*([eE][+-]?\d+)?" => s"\1***\2",
    ],
    checkdocs=:exports,
)

if get(ENV, "CI", "false") == "true"
    deploydocs(
        repo="github.com/oecd-nea/Posy2.jl.git",
        devbranch="main",
        devurl="dev",
        versions=[
            "main" => "dev",
            "stable" => "v^",
            "v#.#" => "v#.#",
        ],
        push_preview=true,
    )
end
