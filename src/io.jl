
"Extract a NetCDF variable at a given time"
function get_at!(
    buffer,
    var::NCDatasets.CFVariable,
    times::AbstractVector{<:TimeType},
    t::TimeType,
)
    dim = findfirst(==("time"), NCDatasets.dimnames(var))
    i = findfirst(>=(t), times)
    i === nothing && throw(DomainError("time $t after dataset end $(last(times))"))
    # load in place, using a lower level NCDatasets function
    # currently all indices must be of the same type, so create three ranges
    # https://github.com/Alexander-Barth/NCDatasets.jl/blob/fa742ee1b36c9e4029a40581751a21c140f01f84/src/variable.jl#L372
    spatialdim1 = 1:size(buffer, 1)
    spatialdim2 = 1:size(buffer, 2)

    if dim == 1
        NCDatasets.load!(var.var, buffer, i:i, spatialdim1, spatialdim2)
    elseif dim == 3
        NCDatasets.load!(var.var, buffer, spatialdim1, spatialdim2, i:i)
    else
        error("Time dimension expected at position 1 or 3")
    end
    return buffer
end

function get_at_month!(buffer, var::NCDatasets.CFVariable, m)
    # assumes the dataset has 12 time steps, from January to December
    dim = findfirst(==("time"), NCDatasets.dimnames(var))
    # load in place, using a lower level NCDatasets function
    # currently all indices must be of the same type, so create three ranges
    # https://github.com/Alexander-Barth/NCDatasets.jl/blob/fa742ee1b36c9e4029a40581751a21c140f01f84/src/variable.jl#L372
    spatialdim1 = 1:size(buffer, 1)
    spatialdim2 = 1:size(buffer, 2)

    if dim == 1
        NCDatasets.load!(var.var, buffer, m:m, spatialdim1, spatialdim2)
    elseif dim == 3
        NCDatasets.load!(var.var, buffer, spatialdim1, spatialdim2, m:m)
    else
        error("Time dimension expected at position 1 or 3")
    end
    return buffer
end

"Get dynamic NetCDF input for the given time"
function update_forcing!(model)
    @unpack vertical, clock, reader = model
    @unpack dataset, leafarea_dataset, buffer, inds = reader
    nctimes = nomissing(dataset["time"][:])

    # TODO allow configurable variable names
    precipitation = get_at!(buffer, dataset["P"], nctimes, clock.time)
    vertical.precipitation .= buffer[inds]
    temperature = get_at!(buffer, dataset["TEMP"], nctimes, clock.time)
    vertical.temperature .= buffer[inds]
    potevap = get_at!(buffer, dataset["PET"], nctimes, clock.time)
    vertical.potevap .= buffer[inds]

    # TODO perhaps we should only read this when a new month came
    lai = get_at_month!(buffer, leafarea_dataset["LAI"], month(clock.time))
    vertical.lai .= buffer[inds]

    return model
end

"prepare an output dataset"
function setup_netcdf(
    output_path,
    nclon,
    nclat,
    parameters,
    calendar,
    time_units,
    row,
    maxlayers,
)
    ds = NCDataset(output_path, "c")
    defDim(ds, "time", Inf)  # unlimited
    defVar(
        ds,
        "lon",
        nclon,
        ("lon",),
        attrib = [
            "_FillValue" => NaN,
            "long_name" => "longitude",
            "units" => "degrees_east",
        ],
    )
    defVar(
        ds,
        "lat",
        nclat,
        ("lat",),
        attrib = [
            "_FillValue" => NaN,
            "long_name" => "latitude",
            "units" => "degrees_north",
        ],
    )
    defVar(ds, "layer", collect(1:maxlayers), ("layer",))
    defVar(
        ds,
        "time",
        Float64,
        ("time",),
        attrib = ["units" => time_units, "calendar" => calendar],
    )
    for parameter in parameters
        srctype = eltype(getproperty(row, Symbol(parameter)))
        if srctype <: AbstractFloat
            # all floats are saved as Float32
            defVar(
                ds,
                parameter,
                Float32,
                ("lon", "lat", "time"),
                attrib = ["_FillValue" => Float32(NaN)],
            )
        elseif srctype <: SVector
            # SVectors are used to store layers
            defVar(
                ds,
                parameter,
                Float32,
                ("lon", "lat", "layer", "time"),
                attrib = ["_FillValue" => Float32(NaN)],
            )
        else
            error("Unsupported output type: ", srctype)
        end
    end
    return ds
end

"Add a new time to the unlimited time dimension, and return the index"
function add_time(ds, time)
    i = length(ds["time"]) + 1
    ds["time"][i] = time
    return i
end

function checkdims(dims)
    # TODO check if the x y ordering is equal to the staticmaps NetCDF
    @assert length(dims) == 3
    @assert "time" in dims
    @assert ("x" in dims) || ("lon" in dims)
    @assert ("y" in dims) || ("lat" in dims)
    @assert dims[2] != "time"
    return dims
end

struct NCReader{T}
    dataset::NCDataset
    leafarea_dataset::NCDataset
    buffer::Matrix{T}
    inds::Vector{CartesianIndex{2}}
end

struct NCWriter
    dataset::NCDataset
    parameters::Vector{String}
end

function prepare_reader(path, leafarea_path, varname, inds)
    dataset = NCDataset(path)
    var = dataset[varname].var

    fillvalue = get(var.attrib, "_FillValue", nothing)
    scale_factor = get(var.attrib, "scale_factor", nothing)
    add_offset = get(var.attrib, "add_offset", nothing)
    # TODO support scale_factor and add_offset with in place loading
    # TODO check other forcing parameters as well
    @assert isnothing(fillvalue) || isnan(fillvalue)
    @assert isnothing(scale_factor) || isone(scale_factor)
    @assert isnothing(add_offset) || iszero(add_offset)

    T = eltype(var)
    dims = dimnames(var)
    checkdims(dims)
    timelast = last(dims) == "time"
    lateral_size = timelast ? size(var)[1:2] : size(var)[2:3]
    buffer = zeros(T, lateral_size)

    # set in inifile? Also type (monthly, daily, hourly) as part of netcdf variable attribute?
    # in original inifile: LAI=staticmaps/clim/LAI,monthlyclim,1.0,1
    # TODO:include LAI climatology in update() vertical SBM model
    # we currently assume the same dimension ordering as the forcing
    leafarea_dataset = NCDataset(leafarea_path)

    return NCReader(dataset, leafarea_dataset, buffer, inds)
end

function prepare_writer(config, reader, output_path, row, maxlayers)
    # TODO remove random string from the filename
    # this makes it easier to develop for now, since we don't run into issues with open files
    base, ext = splitext(output_path)
    randomized_path = string(base, '_', randstring('a':'z', 4), ext)

    nclon = Float64.(nomissing(reader.dataset["lon"][:]))
    nclat = Float64.(nomissing(reader.dataset["lat"][:]))

    output_parameters = config.output.parameters
    calendar = get(config.input, "calendar", "proleptic_gregorian")
    time_units = get(config.input, "time_units", CFTime.DEFAULT_TIME_UNITS)
    ds = Wflow.setup_netcdf(
        randomized_path,
        nclon,
        nclat,
        output_parameters,
        calendar,
        time_units,
        row,
        maxlayers,
    )
    return NCWriter(ds, output_parameters)
end

"Write NetCDF output"
function write_output(model, writer::NCWriter)
    @unpack vertical, clock, reader = model
    @unpack buffer, inds = reader
    @unpack dataset, parameters = writer

    time_index = add_time(dataset, clock.time)

    for parameter in parameters
        # write the active cells vector to the 2d buffer matrix
        param = Symbol(parameter)
        vector = getproperty(vertical, param)

        elemtype = eltype(vector)
        if elemtype <: AbstractFloat
            # ensure no other information is written
            fill!(buffer, NaN)
            buffer[inds] .= vector
            dataset[parameter][:, :, time_index] = buffer
        elseif elemtype <: SVector
            nlayer = length(first(vector))
            for i = 1:nlayer
                # ensure no other information is written
                fill!(buffer, NaN)
                buffer[inds] .= getindex.(vector, i)
                dataset[parameter][:, :, i, time_index] = buffer
            end
        else
            error("Unsupported output type: ", srctype)
        end
    end

    return model
end
