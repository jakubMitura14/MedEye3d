module ShadersAndVerticiesForSupervoxels
using HDF5, Statistics, LinearAlgebra, KernelAbstractions, NIfTI
using ModernGL, GeometryTypes, GLFW
using ..ForDisplayStructs, ..CustomFragShad, ..ModernGlUtil, ..PrepareWindowHelpers, ..DataStructs, ..TextureManag, ..BasicStructs, ..StructsManag, ..DisplayWords
export createAndInitSupervoxelLineShaderProgram, renderSupervoxelLines, populateNiftiWithH5, get_example_sv_to_render

"""
Function for loading hdf5 data within nifti files for display in the visualizer
The function defaults to the first dataset found in the HDF5 file source.
In order to load HDF5 files with medeye3d, first please convert it into its equivalent Nifti source and then load the nifti file
"""
function populateNiftiWithH5(input_nifti_path::String, hdf5_path::String, output_nifti_path::String, dataset::String="")
    # Load the original NIfTI file
    nii = niread(input_nifti_path)

    # Load the HDF5 data
    h5 = h5open(hdf5_path, "r")

    # Find the first dataset in the HDF5 file
    function find_first_dataset(group)
        for name in keys(group)
            obj = group[name]
            if isa(obj, HDF5.Dataset)
                return obj
            elseif isa(obj, HDF5.Group)
                result = find_first_dataset(obj)
                if result !== nothing
                    return result
                end
            end
        end
        return nothing
    end

    priority_dataset = nothing
    new_data = nothing
    if isempty(dataset)
        priority_dataset = find_first_dataset(h5)
        if priority_dataset === nothing
            error("No datasets found in the HDF5 file")
        end

        if ndims(priority_dataset) != 3
            error("Unsupported dataset dimensionality: ", ndims(first_dataset), ". Only 3-dimensional datasets are supported.")
        end
        # Load the data from the first dataset
    else
        priority_dataset = dataset
    end

    new_data = priority_dataset[:, :, :]
    # Assume spacing, origin, and direction are stored as attributes
    spacing = try
        attr(priority_dataset, "spacing")
    catch
        [1.0, 1.0, 1.0]  # Default spacing if not found
    end

    origin = try
        attr(priority_dataset, "origin")
    catch
        [0.0, 0.0, 0.0]  # Default origin if not found
    end

    direction = try
        attr(priority_dataset, "direction")
    catch
        [1.0 0.0 0.0; 0.0 1.0 0.0; 0.0 0.0 1.0]  # Default direction if not found
    end

    close(h5)

    # Create a new NIfTI object with the same header but new data
    new_nii = NIVolume(
        nii.header,     # Keep the original header
        new_data        # Replace with new data
    )

    # Update the header with spacing, origin, and direction
    new_nii.header.pixdim = (new_nii.header.pixdim[1], Float32(spacing[1]), Float32(spacing[2]), Float32(spacing[3]), new_nii.header.pixdim[5], new_nii.header.pixdim[6], new_nii.header.pixdim[7], new_nii.header.pixdim[8])
    new_nii.header.qoffset_x, new_nii.header.qoffset_y, new_nii.header.qoffset_z = Float32.(origin)

    # Update the srow matrices based on direction
    new_nii.header.srow_x = (Float32(direction[1, 1]), Float32(direction[1, 2]), Float32(direction[1, 3]), Float32(origin[1]))
    new_nii.header.srow_y = (Float32(direction[2, 1]), Float32(direction[2, 2]), Float32(direction[2, 3]), Float32(origin[2]))
    new_nii.header.srow_z = (Float32(direction[3, 1]), Float32(direction[3, 2]), Float32(direction[3, 3]), Float32(origin[3]))

    # Save the new NIfTI file
    niwrite(output_nifti_path, new_nii)
    println("Successfully created new NIfTI file at: ", output_nifti_path)
end


"""
Fragment shader for supervoxel lines
"""
function fragShaderSupervoxelLineSrc()
    return """
    #version 330 core
    out vec4 FragColor;




    void main()
    {
        FragColor = vec4(1.0, 1.0, 0.0, 1.0); // Yellow color
    }
    """
end

function createAndInitSupervoxelLineShaderProgram(vertexShader::UInt32)
    fragmentShaderSourceLine = fragShaderSupervoxelLineSrc()
    fsh = """
    $(fragmentShaderSourceLine)
    """
    lineFragmentShader = createShader(fsh, GL_FRAGMENT_SHADER)
    lineShaderProgram = glCreateProgram()
    glAttachShader(lineShaderProgram, lineFragmentShader)
    glAttachShader(lineShaderProgram, vertexShader)
    glLinkProgram(lineShaderProgram)

    return (lineFragmentShader, lineShaderProgram)
end


@kernel function get_cross_section(axis_index::Int, d::Float64, triangle_arr, res_arr)
    index = @index(Global)
    # Determine the axis index
    cross_section_lines = []
    # Iterate through each triangle
    # for i in 1:size(triangle_arr, 1)
    triangle = triangle_arr[index, :, :]
    points = [triangle[j, :] for j in 1:3]

    # Check if the triangle intersects the plane
    distances = [point[axis_index] - d for point in points]
    signs = sign.(distances)

    # if length(unique(signs)) == 1
    #     # All points are on the same side of the plane, no intersection
    #     continue
    # end

    # Compute intersection points
    intersection_points = []
    for j in 1:3
        p1 = points[j]
        p2 = points[mod1(j + 1, 3)]
        d1 = distances[j]
        d2 = distances[mod1(j + 1, 3)]

        if sign(d1) != sign(d2)
            t = d1 / (d1 - d2)
            intersection_point = p1 + t * (p2 - p1)
            push!(intersection_points, intersection_point)
        end
    end

    # if length(intersection_points) == 2
    # distance = norm(intersection_points[1] - intersection_points[2])
    # push!(cross_section_lines, intersection_points)

    if (axis_index == 1)
        ind1 = 2
        ind2 = 3
    end

    if (axis_index == 2)
        ind1 = 1
        ind2 = 3
    end
    if (axis_index == 3)
        ind1 = 1
        ind2 = 2
    end


    base_index = (index - 1) * 2 * 3
    res_arr[base_index+1] = intersection_points[1][ind1]
    res_arr[base_index+2] = intersection_points[1][ind2]
    res_arr[base_index+3] = 1.0
    res_arr[base_index+4] = intersection_points[2][ind1]
    res_arr[base_index+5] = intersection_points[2][ind2]
    res_arr[base_index+6] = 1.0

    # res_arr[base_index+axis_index]=0.0
    # res_arr[base_index+axis_index+3]=0.0



    # end
    # end
    # end

end


function get_example_sv_to_render(h5_path::String, dataset::String)
    fb = h5open(h5_path, "r")
    #we want only external triangles so we ignore the sv center
    # we also ignore interpolated variance value here
    tetr_dat = fb[dataset][:, 2:4, 1:3, 1]


    #given axis and plane we will look for the triangles that points are less then radius times 2 from the plane
    axis = 3
    plane_dist = 41.0
    radiuss = (Float32(4.5), Float32(4.5), Float32(4.5))
    #in order for a triangle to intersect the plane it has to have at least one point on one side of the plane and at least one point on the other side
    bool_ind = Bool.(Bool.((tetr_dat[:, 1, axis] .< (plane_dist)) .* (tetr_dat[:, 2, axis] .> (plane_dist)))
                     .|| Bool.((tetr_dat[:, 2, axis] .< (plane_dist)) .* (tetr_dat[:, 3, axis] .> (plane_dist)))
                     .|| Bool.((tetr_dat[:, 3, axis] .< (plane_dist)) .* (tetr_dat[:, 1, axis] .> (plane_dist)))
    )

    #filter out too long lines
    # bool_ind_b=Bool.( Bool.(abs.((tetr_dat[:, 1, axis]).-(tetr_dat[:, 2, axis] )).<(maximum(radiuss)*2))
    # .&& Bool.(abs.((tetr_dat[:, 2, axis] ).-(tetr_dat[:, 3, axis])).<(maximum(radiuss)*2))
    # .&& Bool.(abs.((tetr_dat[:, 3, axis] ).-(tetr_dat[:, 1, axis])).<(maximum(radiuss)*2) )
    # )
    # #filter out too short lines
    # bool_ind_c=Bool.( Bool.(abs.((tetr_dat[:, 1, axis]).-(tetr_dat[:, 2, axis] )).>(0.01))
    # .&& Bool.(abs.((tetr_dat[:, 2, axis] ).-(tetr_dat[:, 3, axis])).>(0.0))
    # .&& Bool.(abs.((tetr_dat[:, 3, axis] ).-(tetr_dat[:, 1, axis])).>(0.0) )
    # )


    # bool_ind=bool_ind.&&bool_ind_b.&&bool_ind_c
    # #we will only consider the triangles that intersect the plane
    relevant_triangles = Float32.(tetr_dat[bool_ind, :, :])
    # relevant_triangles=tetr_dat

    # # relevant_triangles[:,:,1]
    # relevant_triangles[50,:,:]

    # Int(round(minimum(relevant_triangles[:,:,1])))

    res = Float32.(zeros(size(relevant_triangles, 1) * 2 * 3))

    # @info size(res)

    dev = get_backend(res)
    get_cross_section(dev, 128)(axis, plane_dist, relevant_triangles, res, ndrange=(size(relevant_triangles, 1)))
    KernelAbstractions.synchronize(dev)

    #GETTING TO OPENGL COORDINATE system
    #NOTE : For floating point number calculation please use Float32 instead of Float64 to prevent straight lines

    res = res .+ 1
    res = res ./ 2
    res = res .- minimum(res)
    res = res ./ maximum(res)

    sizeRes = size(res)[1]
    res = reshape(res, (Int(round(sizeRes / 2)), 2))
    res[:, 1] = res[:, 1] .* Float32(2) #broadcast multiplication
    res[:, 2] = res[:, 2] .* Float32(2)

    # res = res .* Float32(1.6) #redundant
    res = reshape(res, sizeRes)
    res = res .- 1



    # @info "min" minimum(res)
    # @info "max" maximum(res)


    line_indices = UInt32.(collect(0:(size(relevant_triangles, 1)*16)))
    # line_indices=UInt32.(collect(0:(size(relevant_triangles,1)*4)))
    # if (axis == 1)
    #     imm = fb["im"][Int(plane_dist), :, :]
    # end
    # if (axis == 2)
    #     imm = fb["im"][:, Int(plane_dist), :]
    # end
    # if (axis == 3)
    #     imm = fb["im"][:, :, Int(plane_dist)]
    # end
    close(fb)



    # return imm, res, line_indices
    return Dict("supervoxel_vertices" => res, "supervoxel_indices" => line_indices)
end




function renderSupervoxelLines(forDisplayConstants, supervoxel, mainRect, svVertAndInd)
    glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, C_NULL)

    # Switch to crosshair shader and render crosshair
    glUseProgram(supervoxel.shaderProgram)
    glBindVertexArray(supervoxel.vao[])
    # glDrawElements(GL_LINES, 4, GL_UNSIGNED_INT, C_NULL)
    glDrawElements(GL_LINES, Int(round(length(svVertAndInd["supervoxel_indices"]) / 2)), GL_UNSIGNED_INT, C_NULL)

    # Switch back to main shader program
    # using the shader program from the mainRect causes the image render to disappear, so better use the one from forDisplayConstants !!
    glUseProgram(forDisplayConstants.shader_program)
    glBindVertexArray(mainRect.vao[])

    GLFW.SwapBuffers(forDisplayConstants.window)
end

# function updateSupervoxels(forDisplayConstants, supervoxel, mainRect, state)
#     updateImagesDisplayed(state.currentlyDispDat, state.mainForDisplayObjects, state.textDispObj, state.calcDimsStruct, state.valueForMasToSet, state.crosshairFields, state.mainRectFields, state.displayMode)

#     renderLines(forDisplayConstants, supervoxel, mainRect)
# end




# Float32[
#     0.1, 0.0, 0.0,  # top right
#     -0.1, 0.0, 0.0,  # bottom right
#     0.0, -0.1, 0.0,  # bottom left
#     0.0, 0.1, 0.0   # top left
# ]

# # Indices for drawing lines
# supervoxel_indices = UInt32[
#     0, 1,  # Line from top right to bottom right
#     2, 3   # Line from bottom left to top left
# ]


end


"""
Stuff to do :
coordinates are from -1 to 1 if text is right 20 percent of a viewer you need to transform coordinate system of verticies to be from minus 1 to 0.6 ; so first add on then divide by 2 then multiply by 1.6 (of course calculate this value) and subtract 1. The image should be the one from hdf5 just load it as medimage with spacing 1 1 1
"""