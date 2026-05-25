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

readtechdata(filename="tech_data.xlsx") = readexcel(joinpath(pwd(), "data"), filename)
@memoize function gettechdatasheet(xl, sheetname::String) # this function is memoized because gettable is time-consuming
    sns = XLSX.sheetnames(xl)
    if !(sheetname in sns)
        throw(ArgumentError("technology workbook: sheet '$(sheetname)' not found. Available sheets: $(join(string.(sns), ", "))"))
    end
    return DataFrame(XLSX.gettable(xl[sheetname], infer_eltypes=true))
end
function gettechparam(xl, tech::String, param::String, sheetname::String, digits::Int)
    df = gettechdatasheet(xl, sheetname)
    tw = "technology workbook, sheet '$(sheetname)'"
    if !("tech" in names(df))
        throw(ArgumentError("$(tw): expected a parameter name column 'tech' (each row names one parameter). Found columns: $(join(string.(names(df)), ", "))"))
    end
    if !(tech in names(df))
        throw(ArgumentError("$(tw): no technology column '$(tech)'. Columns: $(join(string.(names(df)), ", "))"))
    end
    sub = df[df[!, "tech"] .== param, [tech]]
    if nrow(sub) == 0
        throw(ArgumentError("$(tw): no row with tech=='$(param)' for technology column '$(tech)'"))
    end
    val = first(sub[!, tech])
    if ismissing(val) || (val isa AbstractFloat && isnan(val)) ||(val isa AbstractString && isempty(strip(val)))
        throw(ArgumentError("$(tw): empty or missing value for parameter row tech=='$(param)', technology column '$(tech)'"))
    end
    if val isa Number
        return round(val, digits=digits)
    else
        return val
    end
end
gettechparam(s::Snapshot, tech::String, param::String, sheetname::String; digits=6) = gettechparam(
    haskey(s.options, :techdata) ? s.options[:techdata] :
        throw(ArgumentError("Snapshot.options must include :techdata (e.g. :techdata => readtechdata(\"tech_data_2050.xlsx\"))")),
    tech, param, sheetname, digits
)


readtimeseries(filename="time_series.xlsx") = readexcel(joinpath(pwd(), "data"), filename)
@memoize function gettimeseriesdatasheet(xl, sheetname::String) # this function is memoized because gettable is time-consuming
    sns = XLSX.sheetnames(xl)
    if !(sheetname in sns)
        throw(ArgumentError("time series workbook: sheet '$(sheetname)' not found. Available sheets: $(join(string.(sns), ", "))"))
    end
    return DataFrame(XLSX.gettable(xl[sheetname], infer_eltypes=true))
end
function gettimeseries(xl, title::String, sheetname::String, digits::Int)
    df = gettimeseriesdatasheet(xl, sheetname)
    tw = "time series workbook, sheet '$(sheetname)'"
    if !(title in names(df))
        hint = sheetname == "transfer_capacities" ?
            " For sheet 'transfer_capacities', expected column names follow 'From>To' between zone/node names (e.g. SE3>SE1)." : ""
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
    gettimeseries(
        haskey(s.options, :timeseries) ? s.options[:timeseries] :
            throw(ArgumentError("Snapshot.options must include :timeseries (e.g. :timeseries => readtimeseries(join([\"time_series_2050_fromNT2040\", \".xlsx\"]))).")),
        title, sheetname, digits
    )
end