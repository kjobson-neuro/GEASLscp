#!/bin/bash

## script created by Manuel Taso
## script edited, added to and uploaded to FW by krj

##
### Minimal ASL Pre-processing and CBF Calculation
### Processing Siemens and GE data
##

# Load config or inputs manually
CmdName=$(basename "$0")
Syntax="${CmdName} [-c config][-a ASLZip][-s SubjectID][-j JSON][-p PLD][-l LD][-v][-n Averages]"
function sys {
    [ -n "${opt_n}${opt_v}" ] && echo "$@" 1>&2
    [ -n "$opt_n" ] || "$@"
}

while getopts a:c:i:j:m:s:nvl arg
do
    case "$arg" in
        a|c|j|l|m|n|s|p|v)
                  eval "opt_${arg}='${OPTARG:=1}'" ;;
    esac
done
shift $(( $OPTIND - 1))

# Check if there is a config
# If so, load info from config,
# If not, load data manually
if [ -n "$opt_c" ]; then
	ConfigJsonFile="$opt_c"
else
	ConfigJsonFile="${FLYWHEEL:=.}/config.json"
fi

echo $ConfigJsonFile

#set variables from config
if [ -n "$opt_a" ]; then
	asl_zip="$opt_a"
else
	asl_zip=$( jq '.inputs.dicom_nifti_asl.location.path' "$ConfigJsonFile" | tr -d '"' )
fi

if [ -n "$opt_l" ]; then
        ld_input="$opt_l"
else
        ld_input=$( jq '.config.ld' "$ConfigJsonFile" | tr -d '"' )
fi

if [ -n "$opt_n" ]; then
        avg_input="$opt_n"
else
        avg_input=$( jq '.config.avg' "$ConfigJsonFile" | tr -d '"' )
fi

if [ -n "$opt_p" ]; then
        pld_input="$opt_p"
else
        pld_input=$( jq '.config.pld' "$ConfigJsonFile" | tr -d '"' )
fi

# If the container is being used outside of FW, a JSON file can be fed into the container
if [ -n "$opt_j" ]; then
	input_json="$opt_j"
fi

# Set file paths
flywheel="/flywheel/v0"
[ -e "$flywheel" ] || mkdir "$flywheel"

data_dir="${flywheel}/input"
[ -e "$data_dir" ] || mkdir "$data_dir"

export_dir="${flywheel}/output"
[ -e "$export_dir" ] || mkdir "$export_dir"

std="${data_dir}/std"
[ -e "$std" ] || mkdir "$std"

viz="${export_dir}/viz"
[ -e "$viz" ] || mkdir "$viz"

workdir="${flywheel}/work"
[ -e "$workdir" ] || mkdir "$workdir"

asl_dcmdir="${workdir}/asl_dcmdir"
[ -e "$asl_dcmdir" ] || mkdir "$asl_dcmdir"

stats="${export_dir}/stats"
[ -e "$stats" ] || mkdir "$stats"

exe_dir="${flywheel}/workflows"
[ -e "$exe_dir" ] || mkdir "$exe_dir"

### Get information about the scan
touch ${workdir}/metadata.json

python3 ${exe_dir}/flywheel_context.py

# Check if metadata was created successfully
if [ ! -f "${workdir}/metadata.txt" ]; then
    echo "ERROR: Failed to generate metadata file"
fi

### Data Preprocessing
# Check if the data is a zip file
# Unzip if so

if file "$asl_zip" | grep -q 'Zip archive data'; then
	unzip -d "$asl_dcmdir" "$asl_zip"  
	dcm2niix -f %d -b y -o ${asl_dcmdir}/ "$asl_dcmdir"
else
	cp -r "$asl_zip" ${asl_dcmdir}/
	dcm2niix -f %d -b y -o ${asl_dcmdir}/ "$asl_zip"
fi

# Get nifti files from the zip dir
# Need to do this iteratively because delta image and asl data come in one DICOM folder
# Collect nifti files in the ASL directory
shopt -s nullglob

nifti_files=( "${asl_dcmdir}"/*.nii "${asl_dcmdir}"/*.nii.gz )

echo "Found ${#nifti_files[@]} NIfTI file(s) in ${asl_dcmdir}"

if (( ${#nifti_files[@]} < 2 )); then
    echo "Error: expected at least 2 NIfTI files in ${asl_dcmdir}, but found ${#nifti_files[@]}" >&2
    exit 1
fi

# Assign the two files
vol0="${nifti_files[0]}"
vol1="${nifti_files[1]}"

echo "File 1: ${vol0}"
echo "File 2: ${vol1}"

# Get max values using fslstats
max0=$(fslstats "${vol0}" -R | awk '{print $2}')
max1=$(fslstats "${vol1}" -R | awk '{print $2}')

if [ "$(echo "${max0} < ${max1}" | bc -l)" -eq 1 ]; then
    asl_nifti="${vol0}"
    m0_nifti="${vol1}"
else
    asl_nifti="${vol1}"
    m0_nifti="${vol0}"
fi

# Get number of repition to automatically calculate the m0 scale
# Get JSON file
json_file="${asl_nifti%.nii.gz}.json"
[ ! -f "${json_file}" ] && json_file="${asl_nifti%.nii}.json"

if [ ! -f "${json_file}" ]; then
    echo "Error: JSON file not found"
    exit 1
fi

echo "JSON file used to get input: ${json_file}"

#if these variables do not already exist in the gear, get them from the JSON file
is_valid_number() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

if ! is_valid_number "$avg_input" || \
   ! is_valid_number "$ld_input"  || \
   ! is_valid_number "$pld_input"; then
    # Parse NumberOfAverages using grep and awk
    num_avg=$(grep '"NumberOfAverages"' "${json_file}" | awk -F': ' '{print $2}' | tr -d ', ')
    m0_scale=$(( num_avg * 32 ))
    ld=$(grep '"LabelingDuration"' "${json_file}" | awk -F': ' '{print $2}' | tr -d ', ')
    pld=$(grep '"PostLabelingDelay"' "${json_file}" | awk -F': ' '{print $2}' | tr -d ', ')
    echo "Parsed using JSON file from ASL data."
    echo "NumberOfAverages: ${num_avg}"
    echo "M0 Scale: ${m0_scale}"
    echo "Labeling duration: ${config_ld}"
    echo "Post labeling delay: ${config_pld}"
else
    m0_scale=$(( avg_input * 32))
    ld="$ld_input"
    pld="$pld_input"
    echo "Parsed from Flywheel/Docker input."
    echo "NumberOfAverages: ${avg_input}"
    echo "M0 Scale: ${m0_scale}"
    echo "Labeling duration: ${ld}"
    echo "Post labeling delay: ${pld}"

fi

if [[ -z "$ld" || -z "$pld" || -z "$m0_scale" ]]; then
    echo "Error: One or more required variables are unset or empty."
    exit 1
fi

# Skull-Stripping
${FREESURFER_HOME}/bin/mri_synthstrip -i ${m0_nifti} -m ${workdir}/mask.nii.gz

# Erode mask and use on CBF map
fslmaths ${workdir}/mask.nii.gz -ero ${workdir}/mask_ero.nii.gz

### Calculate CBF
python3 /flywheel/v0/workflows/ge_cbf_calc.py -m0 ${m0_nifti} -asl ${asl_nifti} -m ${workdir}/mask.nii.gz -ld $ld -pld $pld -scale $m0_scale -out ${workdir}
fslmaths ${workdir}/cbf.nii.gz -mas ${workdir}/mask_ero.nii.gz ${workdir}/cbf_mas.nii.gz

# Smoothing ASL image subject space, deforming images to match template
fslmaths ${workdir}/asl_mc.nii.gz -s 1.5 -mas ${workdir}/mask.nii.gz ${workdir}/s_asl.nii.gz 
${ANTSPATH}/antsRegistration --dimensionality 3 --transform "Affine[0.25]" --metric "MI[${std}/batsasl/bats_asl_masked.nii.gz,${workdir}/s_asl.nii.gz,1,32]" --convergence 100x20 --shrink-factors 4x1 --smoothing-sigmas 2x0mm --transform "SyN[0.1]" --metric "CC[${std}/batsasl/bats_asl_masked.nii.gz,${workdir}/s_asl.nii.gz,1,1]" --convergence 40x20 --shrink-factors 2x1 --smoothing-sigmas 2x0mm  --output "[${workdir}/ind2temp,${workdir}/ind2temp_warped.nii.gz,${workdir}/temp2ind_warped.nii.gz]" --collapse-output-transforms 1 --interpolation BSpline -v 1
echo "ANTs Registration finished"

# Warping atlases, deforming ROI
# Standardize CBF images to a common template
# Removed --use-BSpline flag because we do not want to deform the ROIs
${ANTSPATH}/WarpImageMultiTransform 3 ${std}/batsasl/bats_cbf.nii.gz ${workdir}/w_batscbf.nii.gz -R ${workdir}/asl_mc.nii.gz -i ${workdir}/ind2temp0GenericAffine.mat ${workdir}/ind2temp1InverseWarp.nii.gz
list=("arterial2" "cortical" "subcortical" "thalamus" "landau" "schaefer2018") ##list of ROIs

# Eroding some ROIs so that they are not touching the edges of the CBF map and not including incorrect CBF values
# deforming ROI
for str in "${list[@]}"
do
    echo ${str}
    touch ${stats}/tmp_${str}.txt
    touch ${stats}/cbf_${str}.txt
    touch ${stats}/${str}_vox.txt
    echo "Printed ${stats}"
    ${ANTSPATH}/WarpImageMultiTransform 3 ${std}/${str}.nii.gz ${workdir}/w_${str}.nii.gz -R ${workdir}/asl_mc.nii.gz --use-NN -i ${workdir}/ind2temp0GenericAffine.mat ${workdir}/ind2temp1InverseWarp.nii.gz
    fslmaths ${workdir}/w_${str}.nii.gz -mas ${workdir}/mask_ero.nii.gz ${workdir}/w_${str}_mas.nii.gz
    fslstats -K ${workdir}/w_${str}_mas.nii.gz ${workdir}/cbf_mas.nii.gz -M -S > ${stats}/tmp_${str}.txt
    fslstats -K ${workdir}/w_${str}_mas.nii.gz ${workdir}/cbf_mas.nii.gz -V > ${stats}/${str}_vox.txt
    paste ${std}/${str}_label.txt -d ' ' ${stats}/tmp_${str}.txt ${stats}/${str}_vox.txt > ${stats}/cbf_${str}.txt #combine label with values
done

# Original main processing loop with missing label filter
for str in "${list[@]}"
    do
    input_cbf="${stats}/cbf_${str}.txt"
    output_cbf="${stats}/formatted_cbf_${str}.txt"
    temp_dir="/flywheel/v0/work/temp_$(date +%s)"
    mkdir -p "$temp_dir"

    # Create temporary file with updated header
    temp_file="$temp_dir/tmp_cbf_${str}.txt"
    echo "Region | Mean CBF | Standard Deviation | Voxels | Volume" > "$temp_file"

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue  # Skip empty lines

        # Extract numeric values
        mean_cbf=$(echo "$line" | awk '{print $(NF-3)}')
        std_dev=$(echo "$line" | awk '{print $(NF-2)}')
        voxels=$(echo "$line" | awk '{print $(NF-1)}')
        volume=$(echo "$line" | awk '{print $NF}')

        # Extract region name
        region=$(echo "$line" | awk '{
        for (i=1; i<=NF-4; i++)
            printf "%s ", $i;
        }' | sed 's/[[:space:]]$//')

        # Skip lines with 'missing label' or bad entries
        [[ -z "$region" || "$region" == "0" || "$region" == *"missing label"* || "$voxels" < "10" ]] && continue

        # Format numeric values
        formatted_mean=$(printf "%.1f" "$mean_cbf")
        formatted_std=$(printf "%.1f" "$std_dev")
        formatted_voxels=$(printf "%.1f" "$voxels")
        formatted_volume=$(printf "%.1f" "$volume")

        echo "$region | $formatted_mean | $formatted_std | $formatted_voxels | $formatted_volume" >> "$temp_file"
    done < "$input_cbf"

    # Format final output
    column -t -s '|' -o '|' "$temp_file" > "$output_cbf"
    rm -rf "$temp_dir"
done

# Extract these regions to display as a general "AD" check
target_regions=(
    "Left_Hippocampus"
    "Right_Hippocampus"
    "Left_Putamen"
    "Right_Putamen"
    "Cingulate_Gyrus,_posterior_division"
    "Precuneous_Cortex"
    # "Landau_metaROI"  # Added Landau region
)

extracted_file="${stats}/extracted_regions_combined.txt"
echo "Region | Mean CBF | Standard Deviation | Voxels | Volume" > "$extracted_file"

# Process only the three specified formatted files
for type in cortical subcortical landau; do
    source_file="${stats}/formatted_cbf_${type}.txt"

    [[ -f "$source_file" ]] || continue

    while IFS= read -r line; do
        # Skip header line and empty lines
        [[ "$line" == "Region |"* ]] || [[ -z "$line" ]] && continue

        region=$(echo "$line" | awk -F '|' '{print $1}' | xargs)

        for target in "${target_regions[@]}"; do
            if [[ "$region" == "$target" ]]; then
            echo "$line" >> "$extracted_file"
            fi
        done
    done < "$source_file"
done

# Calculate a weighted rCBF value
cortical="${stats}/formatted_cbf_cortical.txt"
subcortical="${stats}/formatted_cbf_subcortical.txt"
landau="${stats}/formatted_cbf_landau.txt"

pcc=$(grep "Cingulate_Gyrus,_posterior_division" "$cortical" | awk -F '|' '{print $2}' | xargs)
pcc_voxel=$(grep "Cingulate_Gyrus,_posterior_division" "$cortical" | awk -F '|' '{print $5}' | xargs)
precuneus=$(grep "Precuneous_Cortex" "$cortical" | awk -F '|' '{print $2}' | xargs)
precuneus_voxel=$(grep "Precuneous_Cortex" "$cortical" | awk -F '|' '{print $5}' | xargs)
hipp_left=$(grep "Left_Hippocampus" "$subcortical" | awk -F '|' '{print $2}' | xargs)
hipp_left_voxel=$(grep "Left_Hippocampus" "$subcortical" | awk -F '|' '{print $5}' | xargs)
hipp_right=$(grep "Right_Hippocampus" "$subcortical" | awk -F '|' '{print $2}' | xargs)
hipp_right_voxel=$(grep "Right_Hippocampus" "$subcortical" | awk -F '|' '{print $5}' | xargs)
grey_left=$(grep "Left_Cerebral_Cortex" "$subcortical" | awk -F '|' '{print $2}' | xargs)
grey_left_vox=$(grep "Left_Cerebral_Cortex" "$subcortical" | awk -F '|' '{print $5}' | xargs)
grey_right=$(grep "Right_Cerebral_Cortex" "$subcortical" | awk -F '|' '{print $2}' | xargs)
grey_right_vox=$(grep "Right_Cerebral_Cortex" "$subcortical" | awk -F '|' '{print $5}' | xargs)
white_left=$(grep "Left_Cerebral_White_Matter" "$subcortical" | awk -F '|' '{print $2}' | xargs)
white_left_vox=$(grep "Left_Cerebral_White_Matter" "$subcortical" | awk -F '|' '{print $5}' | xargs)
white_right=$(grep "Right_Cerebral_White_Matter" "$subcortical" | awk -F '|' '{print $2}' | xargs)
white_right_vox=$(grep "Right_Cerebral_White_Matter" "$subcortical" | awk -F '|' '{print $5}' | xargs)
putamen_left=$(grep "Left_Putamen" "$subcortical" | awk -F '|' '{print $2}' | xargs)
putamen_left_vox=$(grep "Left_Putamen" "$subcortical" | awk -F '|' '{print $5}' | xargs)
putamen_right=$(grep "Right_Putamen" "$subcortical" | awk -F '|' '{print $2}' | xargs)
putamen_right_vox=$(grep "Right_Putamen" "$subcortical" | awk -F '|' '{print $5}' | xargs)
landau_meta=$(grep "Landau_metaROI" "$landau" | awk -F '|' '{print $2}' | xargs)
landau_meta_vox=$(grep "Landau_metaROI" "$landau" | awk -F '|' '{print $5}' | xargs)

# Left and right grey matter
grey_matter_weighted=$(echo "scale=4; ($grey_left * $grey_left_vox + $grey_right * $grey_right_vox) / ($grey_left_vox + $grey_right_vox)" | bc -l)

# Left and right white matter
white_matter_weighted=$(echo "scale=4; ($white_left * $white_left_vox + $white_right * $white_right_vox) / ($white_left_vox + $white_right_vox)" | bc -l)

# Whole brain
whole_brain_weighted=$(echo "scale=4; ($grey_left * $grey_left_vox + $grey_right * $grey_right_vox + $white_left * $white_left_vox + $white_right * $white_right_vox) / ($grey_left_vox + $grey_right_vox + $white_left_vox + $white_right_vox)" | bc -l)
echo $whole_brain_weighted
# Left and right putamen
putamen_weighted=$(echo "scale=4; ($putamen_left * $putamen_left_vox + $putamen_right * $putamen_right_vox) / ($putamen_left_vox + $putamen_right_vox)" | bc -l)

# PCC+Precuneus calculation
pcc_precuneus_weighted=$(echo "scale=4; ($pcc * $pcc_voxel + $precuneus * $precuneus_voxel) / ($pcc_voxel + $precuneus_voxel)" | bc -l)

# Hippocampus calculation
hippocampus_weighted=$(echo "scale=4; ($hipp_left * $hipp_left_voxel + $hipp_right * $hipp_right_voxel) / ($hipp_left_voxel + $hipp_right_voxel)" | bc -l)

# Clear or create the output file
weighted_rcbf="${stats}/weighted_rcbf.txt"
: > $weighted_rcbf

# Overwrite or create the weighted_rCBF file in the same format as formatted_cbf_*.txt
echo "Region | CBF | Voxels" > $weighted_rcbf

# Whole brain
if [[ -n "$whole_brain_weighted" && "$whole_brain_weighted" =~ ^[0-9.]+$ ]]; then
    whole_brain_vox=$(echo "scale=4; ($grey_left_vox + $grey_right_vox + $white_left_vox + $white_right_vox)" | bc -l)
    echo "Whole brain | $whole_brain_weighted | $whole_brain_vox" >> $weighted_rcbf
else
    echo "Whole brain CBF value is not a number"
fi

# Grey Matter
if [[ -n "$grey_matter_weighted" && "$grey_matter_weighted" =~ ^[0-9.]+$ ]]; then
    grey_matter_vox=$(echo "$grey_right_vox + $grey_left_vox" | bc -l)
    echo "Grey_Matter L+R | $grey_matter_weighted | $grey_matter_vox" >> $weighted_rcbf
else
    echo "Grey_Matter_L+R value is not a number"
fi

# White Matter
if [[ -n "$white_matter_weighted" && "$white_matter_weighted" =~ ^[0-9.]+$ ]]; then
    white_matter_vox=$(echo "$white_right_vox + $white_right_vox" | bc -l)
    echo "White_Matter L+R | $white_matter_weighted | $white_matter_vox" >> $weighted_rcbf
else
    echo "White_Matter_L+R value is not a number"
fi

# PCC+Precuneus row
if [[ -n "$pcc_precuneus_weighted" && "$pcc_precuneus_weighted" =~ ^[0-9.]+$ ]]; then
    pcc_precuneus_vox=$(echo "$pcc_voxel + $precuneus_voxel" | bc -l)
    echo "PCC+Precuneus | $pcc_precuneus_weighted | $pcc_precuneus_vox" >> $weighted_rcbf
else
    echo "PCC+Precuneus value is not a number"
fi

# Hippocampus row
if [[ -n "$hippocampus_weighted" && "$hippocampus_weighted" =~ ^[0-9.]+$ ]]; then
    hipp_vox=$(echo "$hipp_right_voxel + $hipp_left_voxel" | bc -l)
    echo "Hippocampus L+R | $hippocampus_weighted | $hipp_vox" >> $weighted_rcbf
else
    echo "Hippocampus_L+R value is not a number"
fi

cat $weighted_rcbf

# Calculate reference CBF values
wholebrain_cbf=$(sed -n 's/[^0-9]*\([0-9]\+\).*/\1/p; q' ${stats}/cbf_wholebrain.txt)

# Add ratio columns to extracted file
temp_file="${stats}/temp_ratio_calc.txt"
awk -F '|' -v put_cbf="$putamen_weighted" '
BEGIN {
    OFS = " | "
    print "Region | Mean | rCBF | Voxels"
}
{
    # Skip empty lines
    if (NF < 3 || $0 ~ /^Region/) next
    
    # Convert to numbers (handles any whitespace)
    mean = $2 + 0
    voxels = $3 + 0
    
    # Calculate rCBF putamen ratio
    rCBF = (mean != 0) ? mean / put_cbf : "NA"
    
    printf "%s | %.0f | %.1f | %.0f\n", \
        $1, mean, rCBF, voxels
}' "$weighted_rcbf" | column -t -s '|' -o '|' > "$temp_file"

weighted_table="${stats}/weighted_table.txt"
mv "$temp_file" "$weighted_table"

# Smoothing the deformation field of images obtained previously
fslmaths ${workdir}/ind2temp1Warp.nii.gz -s 5 ${workdir}/swarp.nii.gz
${ANTSPATH}/WarpImageMultiTransform 3 ${workdir}/asl_mc.nii.gz ${workdir}/s_ind2temp_warped.nii.gz -R ${workdir}/ind2temp_warped.nii.gz --use-BSpline ${workdir}/swarp.nii.gz ${workdir}/ind2temp0GenericAffine.mat
${ANTSPATH}/WarpImageMultiTransform 3 ${workdir}/cbf.nii.gz ${workdir}/wcbf.nii.gz -R ${workdir}/ind2temp_warped.nii.gz --use-BSpline ${workdir}/swarp.nii.gz ${workdir}/ind2temp0GenericAffine.mat
#wt1: t1 relaxation time. common space. 

### tSNR calculation
# Can not do tSNR with GE data?
#fslmaths ${workdir}/sub.nii.gz -Tmean ${workdir}/sub_mean.nii.gz
#fslmaths ${workdir}/sub.nii.gz -Tstd ${workdir}/sub_std.nii.gz
#fslmaths ${workdir}/sub_mean.nii.gz -div ${workdir}/sub_std.nii.gz ${workdir}/tSNR_map.nii.gz

# New list of ROIs as we do not want to include the thalamus in the PDF output
new_list=("arterial2" "cortical" "subcortical") ##list of ROIs - "landau" removed

# Smoothing for viz
## Upsampling to 1mm and then smoothing to 2 voxels for nicer viz
flirt -in ${workdir}/cbf.nii.gz -ref ${workdir}/cbf.nii.gz -applyisoxfm 1.0 -nosearch -out ${workdir}/cbf_1mm.nii.gz -interp spline
flirt -in ${workdir}/mask.nii.gz -ref ${workdir}/mask.nii.gz -applyisoxfm 1.0 -nosearch -out ${workdir}/mask_1mm.nii.gz
fslmaths ${workdir}/cbf_1mm.nii.gz -s 2 ${workdir}/s_cbf_1mm.nii.gz
 
### Visualizations
python3 /flywheel/v0/workflows/not1_viz.py -cbf ${workdir}/s_cbf_1mm.nii.gz -out ${viz}/ -seg_folder ${workdir}/ -seg ${new_list[@]} -mask ${workdir}/mask_1mm.nii.gz
    
### Create PDF file and output data into it for easy viewing
python3 /flywheel/v0/workflows/not1_pdf.py -viz ${viz} -stats ${stats}/ -out ${workdir}/ -seg_folder ${workdir}/ -seg ${new_list[@]}

python3 /flywheel/v0/workflows/qc.py -viz ${viz} -out ${workdir} -seg_folder ${workdir}/ -seg ${new_list[@]}

## Move all files we want easy access to into the output directory
find ${workdir} -maxdepth 1 \( -name "cbf.nii.gz" -o -name "viz" -o -name "stats" -o -name "output.pdf" -o -name "qc.pdf" \) -print0 | xargs -0 -I {} mv {} ${export_dir}/
mv ${export_dir}/stats/tmp* ${workdir}/ 

## Zip the output directory for easy download
## Also zip work dir so people can look at the intermediate data to troubleshoot
zip -q -r ${export_dir}/final_output.zip ${export_dir}
zip -q -r ${export_dir}/work_dir.zip ${workdir}
