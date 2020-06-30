# timestep that the parameter units are defined in
const basetimestep = Second(Day(1))
const Δt = Second(Day(1))

# default parameter values (dict)
const dparams = Dict(
    "Cfmax" => 3.75653 * (Δt / basetimestep),
    "TT" => 0.0,
    "TTM" => 0.0,
    "TTI" => 1.0,
    "WHC" => 0.1,
    "cf_soil" => 0.038,
    "w_soil" => 0.1125 * (Δt / basetimestep),
    "SoilThickness" => 2000.0,
    "InfiltCapSoil" => 100.0,
    "InfiltCapPath" => 10.0,
    "PathFrac" => 0.01,
    "WaterFrac" => 0.0,
    "thetaS" => 0.6,
    "thetaR" => 0.01,
    "AirEntryPressure" => 10.0,
    "KsatVer" => 3000.0 * (Δt / basetimestep),
    "MaxLeakage" => 0.0,
    "c" => 10.0,
    "M" => 300.0,
    "CapScale" => 100.0,
    "rootdistpar" => -500.0,
    "RootingDepth" => 750.0,
    "LAI" => 1.0,
    "Cmax" => 1.0,
    "CanopyGapFraction" => 0.1,
    "EoverR" => 0.1,
    "et_reftopot" => 1.0,
    "KsatVerFrac" => 1.0,
    "KsatHorFrac" => 1.0,
    "N" => 0.072,
    "NRiver" => 0.036,
)

"""
    initialize_sbm_model(config, staticmaps_path, leafarea_path, forcing_path, output_path)

Initial part of the SBM model concept. Reads model parameters from disk, `staticmaps_path` is the file path
of the NetCDF file with model parameters, `leafarea_path` is an optional file path for a NetCDF file with leaf
area index (LAI) values (climatology).
"""
function initialize_sbm_model(
    config,
    staticmaps_path,
    leafarea_path,
    forcing_path,
    output_path,
)

    sizeinmetres = false
    thicknesslayers = SVector(100.0, 300.0, 800.0, mv)
    maxlayers = length(thicknesslayers) # max number of soil layers
    sumlayers = SVector(pushfirst(cumsum(thicknesslayers), 0.0))

    nc = NCDataset(staticmaps_path)
    dims = dimnames(nc["wflow_subcatch"])

    # There is no need to permute the dimensions of the data, since the active indices are
    # correctly calculated in both ways.
    # The dimension order only needs to be known for interpreting the LDD directions
    # and creating the coordinate maps.
    trsp = dims[2] in ("y", "lat")

    subcatch_2d = nc["wflow_subcatch"][:]
    # indices based on catchment
    inds = Wflow.active_indices(subcatch_2d, missing)
    n = length(inds)

    altitude = Float64.(nc["wflow_dem"][:][inds])
    river_2d = nomissing(nc["wflow_river"][:], 0)
    river = river_2d[inds]
    riverwidth_2d = Float64.(nomissing(nc["wflow_riverwidth"][:], 0))
    riverwidth = riverwidth_2d[inds]
    riverlength_2d = Float64.(nomissing(nc["wflow_riverlength"][:], 0))
    riverlength = riverlength_2d[inds]

    # read x, y coordinates and calculate cell length [m]
    y_nc = "y" in keys(nc.dim) ? nomissing(nc["y"][:]) : nomissing(nc["lat"][:])
    x_nc = "x" in keys(nc.dim) ? nomissing(nc["x"][:]) : nomissing(nc["lon"][:])
    if trsp
        y = permutedims(repeat(y_nc, outer = (1, length(x_nc))))[inds]
    else
        y = repeat(y_nc, outer = (1, length(x_nc)))[inds]
    end
    cellength = abs(mean(diff(x_nc)))

    # snow parameters (also set in ini file (snow=True or False)?)
    cfmax = readnetcdf(nc, "Cfmax", inds, dparams)
    tt = readnetcdf(nc, "TT", inds, dparams)
    tti = readnetcdf(nc, "TTI", inds, dparams)
    ttm = readnetcdf(nc, "TTM", inds, dparams)
    whc = readnetcdf(nc, "WHC", inds, dparams)
    w_soil = readnetcdf(nc, "w_soil", inds, dparams)
    cf_soil = readnetcdf(nc, "cf_soil", inds, dparams)

    # soil parameters
    θₛ = readnetcdf(nc, "thetaS", inds, dparams)
    θᵣ = readnetcdf(nc, "thetaR", inds, dparams)
    kv₀ = readnetcdf(nc, "KsatVer", inds, dparams)
    m = readnetcdf(nc, "M", inds, dparams)
    hb = readnetcdf(nc, "AirEntryPressure", inds, dparams)
    soilthickness = readnetcdf(nc, "SoilThickness", inds, dparams)
    infiltcappath = readnetcdf(nc, "InfiltCapPath", inds, dparams)
    infiltcapsoil = readnetcdf(nc, "InfiltCapSoil", inds, dparams)
    maxleakage = readnetcdf(nc, "MaxLeakage", inds, dparams)
    # TODO: store c, kvfrac in staticmaps.nc start at index 1
    c = fill(dparams["c"], (maxlayers, n))
    kvfrac = fill(dparams["KsatVerFrac"], (maxlayers, n))
    for i in [0:1:maxlayers-1;]
        if string("c_", i) in keys(nc)
            c[i+1, :] = Float64.(nc[string("c_", i)][:][inds])
        else
            @warn(string("c_", i, " not found, set to default value ", dparams["c"]))
        end
        if string("KsatVerFrac_", i) in keys(nc)
            kvfrac[i+1, :] = Float64.(nc[string("KsatVerFrac_", i)][:][inds])
        else
            @warn(string(
                "KsatVerFrac_",
                i,
                " not found, set to default value ",
                dparams["KsatVerFrac"],
            ))
        end
    end

    # fraction open water and compacted area (land cover)
    waterfrac = readnetcdf(nc, "WaterFrac", inds, dparams)
    pathfrac = readnetcdf(nc, "PathFrac", inds, dparams)

    # vegetation parameters
    rootingdepth = readnetcdf(nc, "RootingDepth", inds, dparams)
    rootdistpar = readnetcdf(nc, "rootdistpar", inds, dparams)
    capscale = readnetcdf(nc, "CapScale", inds, dparams)
    et_reftopot = readnetcdf(nc, "et_reftopot", inds, dparams)
    # cmax, e_r, canopygapfraction only required when lai climatoly not provided
    cmax = readnetcdf(nc, "Cmax", inds, dparams)
    e_r = readnetcdf(nc, "EoverR", inds, dparams)
    canopygapfraction = readnetcdf(nc, "CanopyGapFraction", inds, dparams)

    # if lai climatology provided use sl, swood and kext to calculate cmax
    if isnothing(leafarea_path) == false
        sl = readnetcdf(nc, "Sl", inds, dparams)
        swood = readnetcdf(nc, "Swood", inds, dparams)
        kext = readnetcdf(nc, "Kext", inds, dparams)
        # set in inifile? Also type (monthly, daily, hourly) as part of netcdf variable attribute?
        # in original inifile: LAI=staticmaps/clim/LAI,monthlyclim,1.0,1
        lai_clim = NCDataset(leafarea_path) # TODO:include LAI climatology in update() vertical SBM model
    end

    # these are filled in the loop below
    # TODO see if we can replace this approach
    nlayers = zeros(Int, n)
    act_thickl = zeros(Float64, maxlayers, n)
    s_layers = zeros(Float64, maxlayers + 1, n)
    xl = fill(mv, n)
    yl = fill(mv, n)
    riverfrac = fill(mv, n)

    for i = 1:n
        act_thickl_, nlayers_ =
            set_layerthickness(soilthickness[i], sumlayers, thicknesslayers)
        s_layers_ = pushfirst(cumsum(act_thickl_), 0.0)

        xl[i] = sizeinmetres ? cellength : lattometres(y[i])[1] * cellength
        yl[i] = sizeinmetres ? cellength : lattometres(y[i])[2] * cellength
        riverfrac[i] =
            Bool(river[i]) ? min((riverlength[i] * riverwidth[i]) / (xl[i] * yl[i]), 1.0) :
            0.0

        nlayers[i] = nlayers_
        act_thickl[:, i] = act_thickl_
        s_layers[:, i] = s_layers_
    end

    # needed for derived parameters below
    act_thickl = svectorscopy(act_thickl, Val{maxlayers}())
    θₑ = θₛ .- θᵣ
    soilwatercapacity = soilthickness .* θₑ
    satwaterdepth = 0.85 .* soilwatercapacity

    # copied to array of sarray below
    vwc = fill(mv, maxlayers, n)
    vwc_perc = fill(mv, maxlayers, n)

    # Create a TypedTables.Table with all parameters, forcings, output and states used by
    # the model.
    # Each row in the table corresponds to the values of a single cell.
    # For parameters that are constant over space and time, use `Fill(val, n)` to reduce
    # memory usage. This behaves like a Vector of length n, but is backed only by a single
    # scalar value.
    # A column needs to be added to this table, to be able to update it dynamically (input),
    # or to output the value. States need to be in this table to bring their values to the
    # next timestep. If a column is derived from other columns and is not a state, it does
    # not need to be in the table. The only exception is if the column is needed in the
    # output.
    # This table and the memory allocated for the columns are intended to be reused for all
    # timesteps. The Table itself is immutable so no new columns can be added after it is
    # created. The individual columns are (with the exeption off Fill) Vectors, meaning
    # that their values can be updated at any time. To make it easy to reason about the
    # state of the Table at any given time, we shall take care to update the changed values
    # only at the end of each function. This means that in a function for time step T,
    # the table will hold the values of the end of time step T-1, and are updated to step T
    # at the end of the function.
    # Normally speaking a TypedTables.Table allows fast iteration over rows, creating a
    # NamedTuple for each row. Due to the large number of columns used for SBM, it seems
    # Julia's type inference gives up, likely because the typle inference length cutoff
    # is set to 32. The result is that the code will become drastically slower when looping
    # over the rows, since it doesn't know the type of the NamedTuple that represents the
    # row. We got around this limitation by instead of iterating over the table to get rows
    # 1 to n, to iterate over 1:n and fetch the values like t.c[r], where t is the table,
    # c the column, and r the row number.

    # states:
    # satwaterdepth
    # snow
    # tsoil
    # ustorelayerdepth
    # snowwater
    # canopystorage

    sbm = Table(
        # Maximum number of soil layers
        maxlayers = Fill(maxlayers, n),
        # Number of soil layers
        nlayers = nlayers,
        # length of cells in y direction [m]
        yl = yl,
        # length of cells in x direction [m]
        xl = xl,
        # Fraction of river [-]
        riverfrac = riverfrac,
        # Degree-day factor [mm ᵒC⁻¹ Δt⁻¹]
        cfmax = cfmax,
        # Threshold temperature for snowfall [ᵒC]
        tt = tt,
        # Threshold temperature interval length [ᵒC]
        tti = tti,
        # Threshold temperature for snowmelt [ᵒC]
        ttm = ttm,
        # Water holding capacity as fraction of current snow pack [-]
        whc = whc,
        # Soil temperature smooth factor [-]
        w_soil = w_soil,
        # Controls soil infiltration reduction factor when soil is frozen [-]
        cf_soil = cf_soil,
        # Saturated water content (porosity) [mm mm⁻¹]
        θₛ = θₛ,
        # Residual water content [mm mm⁻¹]
        θᵣ = θᵣ,
        # Vertical hydraulic conductivity [mm Δt⁻¹] at soil surface
        kv₀ = kv₀,
        # Muliplication factor [-] applied to kv_z (vertical flow)
        kvfrac = svectorscopy(kvfrac, Val{maxlayers}()),
        # Parameter [mm] controlling f
        m = m,
        # Air entry pressure [cm] of soil (Brooks-Corey)
        hb = hb,
        # Soil thickness [mm]
        soilthickness = soilthickness,
        # Thickness of soil layers [mm]
        act_thickl = act_thickl,
        # Cumulative sum of soil layers [mm], starting at soil surface (0)
        sumlayers = svectorscopy(s_layers, Val{maxlayers + 1}()),
        # Infiltration capacity of the compacted areas [mm Δt⁻¹]
        infiltcappath = infiltcappath,
        # Soil infiltration capacity [mm/Δt]
        infiltcapsoil = infiltcapsoil,
        # Maximum leakage [mm/Δt] from saturated zone
        maxleakage = maxleakage,
        # Fraction of open water (excluding rivers) [-]
        waterfrac = max.(waterfrac .- riverfrac, 0.0),
        # Fraction of compacted area  [-]
        pathfrac = pathfrac,
        # Vertical elevation [m]
        altitude = altitude,
        # Rooting depth [mm]
        rootingdepth = rootingdepth,
        # Controls how roots are linked to water table [-]
        rootdistpar = rootdistpar,
        # Parameter [mm] controlling capilary rise
        capscale = capscale,
        # Multiplication factor [-] to correct
        et_reftopot = et_reftopot,
        # Specific leaf storage [mm]
        sl = sl,
        # Storage woody part of vegetation [mm]
        swood = swood,
        # Extinction coefficient [-] (to calculate canopy gap fraction)
        kext = kext,
        # Brooks-Corey power coefﬁcient [-] for each soil layer
        c = svectorscopy(c, Val{maxlayers}()),
        # Leaf area index [m² m⁻²]
        lai = Fill(1.0, n),
        # Maximum canopy storage [mm]
        cmax = cmax,
        # Canopy gap fraction [-]
        canopygapfraction = canopygapfraction,
        # Gash interception model parameter, ratio of the average evaporation from the
        # wet canopy [mm Δt⁻¹] and the average precipitation intensity [mm Δt⁻¹] on a saturated canopy
        e_r = e_r,
        # Stemflow [mm]
        stemflow = fill(mv, n),
        # Throughfall [mm]
        throughfall = fill(mv, n),
        # A scaling parameter [mm⁻¹] (controls exponential decline of kv₀)
        f = θₑ ./ m,
        # Amount of water in the unsaturated store, per layer [mm]
        ustorelayerdepth = act_thickl .* 0.0,
        # Saturated store [mm]
        satwaterdepth = satwaterdepth,
        # Pseudo-water table depth [mm] (top of the saturated zone)
        zi = max.(0.0, soilthickness .- satwaterdepth ./ θₑ),
        # Soilwater capacity [mm]
        soilwatercapacity = soilwatercapacity,
        # Snow storage [mm]
        snow = fill(0.0, n),
        # Liquid water content in the snow pack [mm]
        snowwater = fill(0.0, n),
        # Snow melt + precipitation as rainfall [mm]
        rainfallplusmelt = fill(mv, n),
        # Top soil temperature [ᵒC]
        tsoil = Fill(10.0, n),
        # Canopy storage [mm]
        canopystorage = fill(0.0, n),
        # Precipitation [mm]
        precipitation = fill(mv, n),
        # Temperature [ᵒC]
        temperature = fill(mv, n),
        # Potential evapotranspiration [mm]
        potevap = fill(mv, n),
        # Potential transpiration, open water, river and soil evaporation (after subtracting interception from potevap)
        pottrans_soil = fill(mv, n),
        # Transpiration [mm]
        transpiration = fill(mv, n),
        # Actual evaporation from unsaturated store [mm]
        ae_ustore = fill(mv, n),
        # Actual evaporation from saturated store [mm]
        ae_sat = fill(mv, n),
        # Interception [mm]
        interception = fill(mv, n),
        # Soil evaporation [mm]
        soilevap = fill(mv, n),
        # Actual evaporation from saturated store (transpiration and soil evaporation) [mm]
        actevapsat = fill(mv, n),
        # Total actual evapotranspiration [mm]
        actevap = fill(mv, n),
        # Runoff from river based on riverfrac [mm]
        runoff_river = fill(mv, n),
        # Runoff from land based on waterfrac [mm]
        runoff_land = fill(mv, n),
        # Actual evaporation from open water (land) [mm]
        ae_openw_l = fill(mv, n),
        # Actual evaporation from river [mm]
        ae_openw_r = fill(mv, n),
        # Water available for infiltration [mm]
        avail_forinfilt = fill(mv, n),
        # Actual infiltration into the unsaturated zone [mm]
        actinfilt = fill(mv, n),
        # Actual infiltration non-compacted fraction [mm]
        actinfiltsoil = fill(mv, n),
        # Actual infiltration compacted fraction [mm]
        actinfiltpath = fill(mv, n),
        # Infiltration excess water [mm]
        infiltexcess = fill(mv, n),
        # Water that cannot infiltrate due to saturated soil (saturation excess) [mm]
        excesswater = fill(mv, n),
        # Water exfiltrating during saturation excess conditions [mm]
        exfiltsatwater = fill(mv, n),
        # Water exfiltrating from unsaturated store because of change in water table [mm]
        exfiltustore = fill(mv, n),
        # Excess water for non-compacted fraction [mm]
        excesswatersoil = fill(mv, n),
        # Excess water for compacted fraction [mm]
        excesswaterpath = fill(mv, n),
        # Total surface runoff from infiltration and saturation excess [mm]
        runoff = fill(mv, n),
        # Volumetric water content [mm mm⁻¹] per soil layer (including θᵣ and saturated zone)
        vwc = svectorscopy(vwc, Val{maxlayers}()),
        # Volumetric water content [%] per soil layer (including θᵣ and saturated zone)
        vwc_perc = svectorscopy(vwc_perc, Val{maxlayers}()),
        # Root water storage [mm] in unsaturated and saturated zone (excluding θᵣ)
        rootstore = fill(mv, n),
        # Volumetric water content [mm mm⁻¹] in root zone (including θᵣ and saturated zone)
        vwc_root = fill(mv, n),
        # Volumetric water content [%] in root zone (including θᵣ and saturated zone)
        vwc_percroot = fill(mv, n),
        # Amount of available water in the unsaturated zone [mm]
        ustoredepth = fill(mv, n),
        # Downward flux from unsaturated to saturated zone [mm]
        transfer = fill(mv, n),
        # Capillary rise [mm]
        capflux = fill(mv, n),
        # Net recharge to saturated store [mm]
        recharge = fill(mv, n),
    )

    inds_riv = filter(i -> !isequal(river_2d[i], 0), inds)
    # reservoirs
    # read only reservoir data if reservoirs true (from model reader, setting Config.jl TOML)
    reslocs_2d = Int.(nomissing(nc["wflow_reservoirlocs"][:], 0))
    # allow reservoirs only in river cells
    inds_res = filter(i -> reslocs_2d[inds][i] > 0 && isequal(river[i], 1), 1:n)
    resdemand = Float64.(nomissing(nc["ResDemand"][:][inds_riv], 0))
    resmaxrelease = Float64.(nomissing(nc["ResMaxRelease"][:][inds_riv], 0))
    resmaxvolume = Float64.(nomissing(nc["ResMaxVolume"][:][inds_riv], 0))
    resarea = Float64.(nomissing(nc["ResSimpleArea"][:][inds_riv], 0))
    res_targetfullfrac = Float64.(nomissing(nc["ResTargetFullFrac"][:][inds_riv], 0))
    res_targetminfrac = Float64.(nomissing(nc["ResTargetMinFrac"][:][inds_riv], 0))
    reslocs = reslocs_2d[inds_riv]

    pits = zeros(Int, n)
    pits[inds_res] .= 1

    reservoirs = [
        reslocs[i] == 0 ? nothing :
            SimpleReservoir{Float64}(
            demand = resdemand[i],
            maxrelease = resmaxrelease[i],
            maxvolume = resmaxvolume[i],
            area = resarea[i],
            targetfullfrac = res_targetfullfrac[i],
            targetminfrac = res_targetminfrac[i],
            Δt = Float64(Δt.value),
        ) for i = 1:length(reslocs)
    ]

    # lateral part sbm
    khfrac = readnetcdf(nc, "KsatHorFrac", inds, dparams)
    βₗ = Float64.(nc["Slope"][:][inds])
    clamp!(βₗ, 0.00001, Inf)
    ldd_2d = nc["wflow_ldd"][:]
    ldd = ldd_2d[inds]
    kh₀ = khfrac .* kv₀
    dl = fill(mv, n)
    dw = fill(mv, n)

    for i = 1:n
        dl[i] = detdrainlength(ldd[i], xl[i], yl[i])
        dw[i] = detdrainwidth(ldd[i], xl[i], yl[i])
    end

    ssf = LateralSSF{Float64}(
        kh₀ = kh₀,
        f = sbm.f,
        zi = sbm.zi,
        soilthickness = soilthickness,
        θₑ = θₛ .- θᵣ,
        Δt = 1.0,
        βₗ = βₗ,
        dl = dl .* 1000.0,
        dw = dw .* 1000.0,
        wb_pit = pits,
    )

    n_land = readnetcdf(nc, "N", inds, dparams)

    olf = SurfaceFlow(
        sl = βₗ,
        n = n_land,
        dl = dl,
        Δt = Float64(Δt.value),
        width = dw,
        wb_pit = pits,
    )

    pcr_dir = trsp ? permute_indices(Wflow.pcrdir) : Wflow.pcrdir
    dag = flowgraph(ldd, inds, pcr_dir)


    riverslope = Float64.(nc["RiverSlope"][:][inds_riv])
    clamp!(riverslope, 0.00001, Inf)
    riverlength = riverlength_2d[inds_riv]
    riverwidth = riverwidth_2d[inds_riv]
    n_river = readnetcdf(nc, "N_River", inds_riv, dparams)
    ldd_riv = ldd_2d[inds_riv]
    dag_riv = flowgraph(ldd_riv, inds_riv, pcr_dir)

    rf = SurfaceFlow(
        sl = riverslope,
        n = n_river,
        dl = riverlength,
        Δt = Float64(Δt.value),
        width = riverwidth,
        reservoir = reservoirs,
        rivercells = river,
    )

    starttime = DateTime(2000, 1, 1)
    reader = prepare_reader(forcing_path, "P", inds)
    writer = prepare_writer(config, reader, output_path, first(sbm), maxlayers)

    model = Model(
        (land = dag, river = dag_riv),
        (subsurface = ssf, land = olf, river = rf),
        sbm,
        Clock(starttime, 1, Δt),
        reader,
        writer,
    )

    # make sure the forcing is already loaded
    # it's fine to run twice, and may help catching errors earlier
    update_forcing!(model)
    return model
end
