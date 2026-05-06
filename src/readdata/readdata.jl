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
    return DataFrame(XLSX.gettable(xl[sheetname], infer_eltypes=true))
end
function gettechparam(xl, tech::String, param::String, sheetname::String, digits::Int)
    df = gettechdatasheet(xl, sheetname)
    val = first(df[df[!,:tech] .== param, tech])
    if val isa Number
        return round(val, digits=digits)
    else
        return val
    end
end
gettechparam(s::Snapshot, tech::String, param::String, sheetname::String; digits=6) = gettechparam(s.options[:techdata], tech, param, sheetname, digits)


readtimeseries(filename="time_series.xlsx") = readexcel(joinpath(pwd(), "data"), filename)
@memoize function gettimeseriesdatasheet(xl, sheetname::String) # this function is memoized because gettable is time-consuming
    return DataFrame(XLSX.gettable(xl[sheetname], infer_eltypes=true))
end
function gettimeseries(xl, title::String, sheetname::String, digits::Int)
    df = gettimeseriesdatasheet(xl, sheetname)
    return round.(df[!,title], digits=digits)
end
function gettimeseries(s::Snapshot, title::String, sheetname::String; digits=6)
    gettimeseries(s.options[:timeseries], title, sheetname, digits)
end