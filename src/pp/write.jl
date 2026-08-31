import XLSX
using OrderedCollections: LittleDict

"""
    write_results(s::Snapshot{Float64}, path::String; overwrite::Bool=false)
Write the standard Posy2 workbook report of the extracted snapshot `s` to
`path` and return `path`. Missing parent directories are created.

`path` is taken as given, extension included; nothing is prepended to it. An
existing file is never touched unless `overwrite=true` is passed, in which case
it is replaced.
"""
function write_results(s::Snapshot{Float64}, path::String; overwrite::Bool=false)
    if !overwrite && isfile(path)
        throw(ArgumentError("$path already exists; pass overwrite=true to replace it"))
    end
    # generate data before opening the file
    dat = _gensnapshotpp(s)

    mkpath(dirname(path))
    _write_results(dat, path)
    return path
end
write_results(::Snapshot, ::String; overwrite::Bool=false) = throw(AssertionError("Snapshot is not optimized"))

function _gensnapshotpp(s::Snapshot)
    return LittleDict(
        "Annual values (all)" => _annual_post_processing_all(s),
        "Annual values (self)" => _annual_post_processing_self(s),
        "Losses" => genlosses(s),
        "Time series" => gentimeseries(s),
        "Price duration curves" => genpricecurves(s),
    )
end

# write one sheet per value in dat
function _write_results(dat, filepath::String)
    # write in file
    XLSX.openxlsx(filepath, mode="w") do xf

        sheetindex = 1
        for (k,v) in dat
            
            if sheetindex == 1
                XLSX.rename!(xf[sheetindex], k)
            else
                XLSX.addsheet!(xf, k)
            end
            
            _write!(xf[sheetindex], v)
            sheetindex += 1

        end

    end

    return nothing
end

_round(x) = x
_round(x::Float64) = round(x, digits=3)

# write one line (dict format) to an XLSX sheet
function __write_to_sheet!(sh, d::DataLine{<:AbstractDict}, row=1)
    sh[XLSX.CellRef(row,1)] = d.title
    sh[XLSX.CellRef(row+1,1)] = d.unit
    local c = 1
    for (k,v) in d.d
        sh[XLSX.CellRef(row+2,c)] = k
        if !isnothing(v) && !ismissing(v)
            sh[XLSX.CellRef(row+3,c)] = _round(v)
        end
        c += 1
    end
    return row + 6
end

# write one line (dataframe format) to an XLSX sheet
function __write_to_sheet!(sh, d::DataLine{<:DataFrame}, row=1)
    sh[XLSX.CellRef(row,1)] = d.title
    sh[XLSX.CellRef(row+1,1)] = d.unit
    local c = 1
    for k in names(d.d)
        sh[XLSX.CellRef(row+2,c)] = k
        for r in 1:nrow(d.d)
            v = d.d[r,k]
            if !isnothing(v) && !ismissing(v)
                sh[XLSX.CellRef(row+2+r,c)] = _round(v)
            end
        end
        c += 1
    end
    return row + 5 + nrow(d.d)
end

# write a vector of DataLine to a sheet
function _write_to_sheet!(sh, v::AbstractVector)
    local row = 1
    for e in v
        row = __write_to_sheet!(sh, e, row)
    end
end

 __write_to_sheet!(sh, ::Nothing, row=1) = row

_write!(sh, a::DataFrame) = !isempty(a) && XLSX.writetable!(sh, a)
_write!(sh, a::AbstractVector) = _write_to_sheet!(sh, a)