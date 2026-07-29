using Documenter
using POSY2
using Nosy

DocMeta.setdocmeta!(
    POSY2,
    :DocTestSetup,
    :(using POSY2, Nosy),
    recursive=true,
)

doctest_setting = get(ENV, "DOCUMENTER_DOCTEST", "true")
doctest_value = doctest_setting == "fix" ? :fix : parse(Bool, doctest_setting)

branch = get(ENV, "GITHUB_REF_NAME", "main")
is_tag = get(ENV, "GITHUB_REF_TYPE", "branch") == "tag"

docs_version = is_tag ? "stable" : branch
edit_branch = is_tag ? nothing : branch

makedocs(
    modules=[POSY2],
    sitename="POSY2.jl",
    authors="Guillaume KRIVTCHIK, OECD Nuclear Energy Agency, and contributors",
    repo="https://github.com/GKrivtchik/POSY2.jl/blob/{commit}{path}#L{line}",
    format=Documenter.HTML(
        prettyurls=get(ENV, "CI", "false") == "true",
        canonical="https://gkrivtchik.github.io/POSY2.jl/$(docs_version)/",
        repolink="https://github.com/GKrivtchik/POSY2.jl",
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
                "Hydrogen" => "components/hydrogen.md",
                "Storage and Conversion" => "components/storage-conversion.md",
                "Interconnections" => "components/interconnections.md",
            ],
            "Extending POSY2" => "concepts/extending.md",
            "Optimizing a Snapshot" => "concepts/optimizing.md",
            "Querying a Snapshot" => "concepts/querying.md",
            "Exporting Results" => "concepts/exporting.md",
        ],
        "Performance" => "performance.md",
        "Examples" => [
            "Overview" => "examples.md",
            "One Country" => "examples/one-country.md",
            "Two Countries" => "examples/two-countries.md",
            "Price Interconnection" => "examples/price-interconnection.md",
            "DC OPF" => "examples/dc-opf.md",
            "Dispatchable Generation" => "examples/dispatchable-generation.md",
            "Battery Storage" => "examples/battery-storage.md",
            "Hydro Reservoir" => "examples/hydro-reservoir.md",
            "Pumped Storage" => "examples/pumped-storage-hydro.md",
            "Hydrogen Production" => "examples/hydrogen-production.md",
            "Electric Vehicles" => "examples/electric-vehicles.md",
            "Demand Response" => "examples/demand-response.md",
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
        repo="github.com/GKrivtchik/POSY2.jl.git",
        devbranch="main",
        devurl="dev",
        versions=[
            "main" => "main",
            "stable" => "v^",
            "v#.#" => "v#.#",
        ],
        push_preview=true,
    )
end
