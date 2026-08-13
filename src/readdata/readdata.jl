"""
Read data to generate the dataset.
"""

using XLSX, DataFrames
using Memoize

# read the xlsx file
# if it is already open, make a temp copy, read the copy, and delete the copy
# the function is memoized with memoization dispatch on last file modification time
@memoize function saferead(path::String, fname::String, mtime) # memoize with dispatch on mtime
    fpath = joinpath(path, fname)
    try
        return XLSX.readxlsx(fpath)
    catch
        _fpath = tempname(path)
        cp(fpath, _fpath)
        xl = XLSX.readxlsx(_fpath)
        rm(_fpath) 
        return xl
    end
end

function readexcel(path, fname)
    mtime = stat(joinpath(path, fname)).mtime # modification time of file
    return saferead(path, fname, mtime)
end

"""
    readtechdata(filename="tech_data.xlsx"; data_dir=joinpath(pwd(), "data"))

Open and return the Posy2 technology-parameter workbook at
`joinpath(data_dir, filename)`.

The workbook is cached by path, filename, and modification time. If another
application has locked the file, Posy2 reads a temporary copy when possible.
"""
readtechdata(filename="tech_data.xlsx"; data_dir=joinpath(pwd(), "data")) = readexcel(data_dir, filename)
@memoize function gettechdatasheet(xl, sheetname::String) # this function is memoized because gettable is time-consuming
    sns = XLSX.sheetnames(xl)
    if !(sheetname in sns)
        throw(ArgumentError("technology workbook: sheet '$(sheetname)' not found. Available sheets: $(join(string.(sns), ", "))"))
    end
    return DataFrame(XLSX.gettable(xl[sheetname], infer_eltypes=true))
end

"""
    gettechparam(xl, techkey::String, param::String, sheetname::String, digits::Int)
    gettechparam(s::Snapshot, techkey::String, param::String, sheetname::String;
        digits=6)

Read one technology parameter from `sheetname`. Technology sheets use a
`tech` column for parameter names and one column per technology; `techkey`
selects the technology column and `param` selects the row.

The snapshot method resolves the workbook through [`Posy2Options`](@ref) when
`tech_mode=:excel`; `:arguments` rejects direct snapshot lookups.
Numeric values are rounded to `digits`; strings, including semicolon-separated
construction profiles, are returned unchanged. Missing sheets, columns, rows,
or values raise `ArgumentError` with workbook context.
"""
function gettechparam(xl, techkey::String, param::String, sheetname::String, digits::Int)
    df = gettechdatasheet(xl, sheetname)
    tw = "technology workbook, sheet '$(sheetname)'"
    if !("tech" in names(df))
        throw(ArgumentError("$(tw): expected a parameter name column 'tech' (each row names one parameter). Found columns: $(join(string.(names(df)), ", "))"))
    end
    if !(techkey in names(df))
        throw(ArgumentError("$(tw): no technology column '$(techkey)'. Columns: $(join(string.(names(df)), ", "))"))
    end
    sub = df[df[!, "tech"] .== param, [techkey]]
    if nrow(sub) == 0
        throw(ArgumentError("$(tw): no row with tech=='$(param)' for technology column '$(techkey)'"))
    end
    val = first(sub[!, techkey])
    if ismissing(val) || (val isa AbstractFloat && isnan(val)) ||(val isa AbstractString && isempty(strip(val)))
        throw(ArgumentError("$(tw): empty or missing value for parameter row tech=='$(param)', technology column '$(techkey)'"))
    end
    if val isa Real
        return round(val, digits=digits)
    else
        return val
    end
end
function gettechparam(s::Snapshot, techkey::String, param::String, sheetname::String; digits=6)
    opts = posy_options(s)
    opts.tech_mode === :excel || throw(ArgumentError(
        "technology parameter '$param' for $sheetname/$techkey must be supplied explicitly " *
        "when tech_mode=:arguments"))
    xl = readtechdata(opts.techdata_file; data_dir=opts.data_dir)
    return gettechparam(xl, techkey, param, sheetname, digits)
end

"""
    readtimeseries(filename="time_series.xlsx";
        data_dir=joinpath(pwd(), "data"))

Open and return the Posy2 hourly time-series workbook at
`joinpath(data_dir, filename)`.

The workbook is cached by path, filename, and modification time. If another
application has locked the file, Posy2 reads a temporary copy when possible.
"""
readtimeseries(filename="time_series.xlsx"; data_dir=joinpath(pwd(), "data")) = readexcel(data_dir, filename)
@memoize function gettimeseriesdatasheet(xl, sheetname::String) # this function is memoized because gettable is time-consuming
    sns = XLSX.sheetnames(xl)
    if !(sheetname in sns)
        throw(ArgumentError("time series workbook: sheet '$(sheetname)' not found. Available sheets: $(join(string.(sns), ", "))"))
    end
    return DataFrame(XLSX.gettable(xl[sheetname], infer_eltypes=true))
end

"""
    gettimeseries(xl, title::String, sheetname::String, digits::Int)
    gettimeseries(s::Snapshot, title::String, sheetname::String; digits=6)

Read and return the complete column `title` from `sheetname` in a Posy2
time-series workbook.

The snapshot method resolves the workbook through [`Posy2Options`](@ref) when
`timeseries_mode=:excel`; `:arguments` rejects direct snapshot lookups.
Values are rounded to `digits`. Missing sheets or columns, and columns
containing `missing` or `NaN`, raise `ArgumentError` with workbook context.
"""
function gettimeseries(xl, title::String, sheetname::String, digits::Int)
    df = gettimeseriesdatasheet(xl, sheetname)
    tw = "time series workbook, sheet '$(sheetname)'"
    if !(title in names(df))
        hint = sheetname == "transfer_capacities" ?
            " For sheet 'transfer_capacities', expected column names follow 'From>To' between zone/node names (e.g. country3>country1)." : ""
        throw(ArgumentError("$(tw): no column '$(title)'.$(hint) Columns: $(join(string.(names(df)), ", "))"))
    end
    for (i, x) in enumerate(df[!, title])
        if ismissing(x) || (x isa AbstractFloat && isnan(x))
            throw(ArgumentError("$(tw): column '$(title)' contains missing or NaN at index $(i) ($(length(df[!, title])) values in column)"))
        end
    end
    return round.(df[!, title], digits=digits)
end
function gettimeseries(s::Snapshot, title::String, sheetname::String; digits=6)
    opts = posy_options(s)
    opts.timeseries_mode === :excel || throw(ArgumentError(
        "time series '$title' from sheet '$sheetname' must be supplied explicitly " *
        "when timeseries_mode=:arguments"))
    xl = readtimeseries(opts.timeseries_file; data_dir=opts.data_dir)
    return gettimeseries(xl, title, sheetname, digits)
end

"""
    _resolve_timeseries(s, value, title, sheetname; keyword="profile", digits=6)

Return an explicitly supplied scalar or vector profile, or load the profile from
the configured workbook when `value === nothing`. Scalars are expanded to the
simulation horizon. Explicit vectors must contain exactly one value per hour.
"""
function _resolve_timeseries(s::Snapshot,
                             value,
                             title::String,
                             sheetname::String;
                             keyword::String="profile",
                             digits::Int=6)
    if isnothing(value)
        opts = posy_options(s)
        opts.timeseries_mode === :excel || throw(ArgumentError(
            "`$keyword` must be supplied explicitly when timeseries_mode=:arguments " *
            "(requested '$title' from sheet '$sheetname')"))
        return gettimeseries(s, title, sheetname; digits=digits)
    end

    nhours = Nosy.nhours(sim(s))
    values = if value isa Real && !(value isa Bool)
        fill(Float64(value), nhours)
    elseif value isa AbstractVector
        length(value) == nhours || throw(ArgumentError(
            "`$keyword` must contain $nhours hourly values, got $(length(value))"))
        result = Vector{Float64}(undef, nhours)
        for (i, x) in enumerate(value)
            (ismissing(x) || !(x isa Real) || x isa Bool) && throw(ArgumentError(
                "`$keyword` contains a non-numeric value at index $i"))
            converted = Float64(x)
            isfinite(converted) || throw(ArgumentError(
                "`$keyword` contains a non-finite value at index $i"))
            result[i] = converted
        end
        result
    else
        throw(ArgumentError("`$keyword` must be a real number or an hourly vector"))
    end

    all(isfinite, values) || throw(ArgumentError("`$keyword` must contain only finite values"))
    return round.(values; digits=digits)
end
