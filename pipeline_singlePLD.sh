#!/bin/bash
#
# GEASLscp Pipeline - Minimal ASL Pre-processing and CBF Calculation
# Original script by Manuel Taso
# Edited, added and uploaded to FW by krj
#
# Processes Siemens and GE ASL data for CBF calculation
#

set -euo pipefail

# ==============================================================================
# INPUT VARIABLES
# ==============================================================================

script_name=$(basename "$0")
syntax="${script_name} [-a ASL input][-m M0 NIfTI][-s SubjectID][-p PLD][-l LD][-n Averages][-e]"

while getopts "a:c:l:m:n:s:p:e" arg; do
    case "$arg" in
        a) opt_a="$OPTARG" ;;
        c) opt_c="$OPTARG" ;;
        e) opt_e=1 ;;
        l) opt_l="$OPTARG" ;;
        m) opt_m="$OPTARG" ;;
        n) opt_n="$OPTARG" ;;
        s) opt_s="$OPTARG" ;;
        p) opt_p="$OPTARG" ;;
        *) echo "Usage: $syntax" >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

# Determine config file location
if [ -n "${opt_c:-}" ]; then
    config_json_file="$opt_c"
else
    config_json_file="${FLYWHEEL:-.}/config.json"
fi

# Load ASL input path
if [ -n "${opt_a:-}" ]; then
    asl_zip="$opt_a"
else
    asl_zip=$(jq -r '.inputs.dicom_nifti_asl.location.path' "$config_json_file")
fi

# Load optional M0 NIfTI path (for NIfTI input)
if [ -n "${opt_m:-}" ]; then
    m0_input="$opt_m"
else
    m0_input=$(jq -r '.inputs.nifti_m0.location.path // empty' "$config_json_file" 2>/dev/null || echo "")
fi

# Load optional parameters from config or command line
ld_input="${opt_l:-$(jq -r '.config.ld // empty' "$config_json_file")}"
avg_input="${opt_n:-$(jq -r '.config.avg // empty' "$config_json_file")}"
pld_input="${opt_p:-$(jq -r '.config.pld // empty' "$config_json_file")}"

# Skip extended analysis flag (registration, atlas, PDF)
if [ -n "${opt_e:-}" ]; then
    skip_extended="true"
else
    skip_extended=$(jq -r '.config.skip_extended // false' "$config_json_file" 2>/dev/null || echo "false")
fi

# ==============================================================================
# PIPELINE CONSTANTS
# ==============================================================================

# ROI atlases for statistical analysis
readonly roi_list=("arterial2" "cortical" "subcortical" "thalamus" "landau" "schaefer2018")

# ROI atlases included in visualization/PDF output
readonly viz_roi_list=("arterial2" "cortical" "subcortical")

# Target regions for AD-related analysis
readonly target_regions=(
    "Left_Hippocampus"
    "Right_Hippocampus"
    "Left_Putamen"
    "Right_Putamen"
    "Cingulate_Gyrus,_posterior_division"
    "Precuneous_Cortex"
)

# ==============================================================================
# DIRECTORY SETUP
# ==============================================================================

flywheel_dir="/flywheel/v0"
[ -e "$flywheel_dir" ] || mkdir -p "$flywheel_dir"

data_dir="${flywheel_dir}/input"
[ -e "$data_dir" ] || mkdir -p "$data_dir"

export_dir="${flywheel_dir}/output"
[ -e "$export_dir" ] || mkdir -p "$export_dir"

std_dir="${data_dir}/std"
[ -e "$std_dir" ] || mkdir -p "$std_dir"

viz_dir="${export_dir}/viz"
[ -e "$viz_dir" ] || mkdir -p "$viz_dir"

work_dir="${flywheel_dir}/work"
[ -e "$work_dir" ] || mkdir -p "$work_dir"

asl_dcm_dir="${work_dir}/asl_dcmdir"
[ -e "$asl_dcm_dir" ] || mkdir -p "$asl_dcm_dir"

stats_dir="${export_dir}/stats"
[ -e "$stats_dir" ] || mkdir -p "$stats_dir"

exe_dir="${flywheel_dir}/workflows"
[ -e "$exe_dir" ] || mkdir -p "$exe_dir"

# ==============================================================================
# UTILITY FUNCTIONS
# ==============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

die() {
    log_error "$@"
    exit 1
}

is_valid_number() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

# Extract a value and voxel count from a formatted stats file
extract_region_stats() {
    local file="$1"
    local region="$2"
    local value_col="${3:-2}"
    local voxel_col="${4:-5}"

    local value voxels
    value=$(grep "$region" "$file" | awk -F '|' "{print \$$value_col}" | xargs)
    voxels=$(grep "$region" "$file" | awk -F '|' "{print \$$voxel_col}" | xargs)

    echo "$value $voxels"
}

# Calculate weighted average of two regions
calc_weighted_avg() {
    local val1="$1" vox1="$2" val2="$3" vox2="$4"
    echo "scale=4; ($val1 * $vox1 + $val2 * $vox2) / ($vox1 + $vox2)" | bc -l
}

# ==============================================================================
# METADATA EXTRACTION
# ==============================================================================

extract_metadata() {
    touch "${export_dir}/metadata.json"
    python3 "${exe_dir}/flywheel_context.py" -dir "${export_dir}"

    if [ ! -f "${export_dir}/metadata.json" ]; then
        log_error "Failed to generate metadata file"
    fi
}

# ==============================================================================
# DATA PREPROCESSING
# ==============================================================================

preprocess_data() {
    log "Starting data preprocessing"

    # Detect input type and process accordingly
    if [[ "$asl_zip" == *.nii.gz ]] || [[ "$asl_zip" == *.nii ]]; then
        # NIfTI input - copy directly, skip dcm2niix
        log "Detected NIfTI input - skipping dcm2niix"
        nifti_input=true

        # Check if M0 NIfTI was provided
        if [ -n "${m0_input:-}" ] && [ -f "${m0_input}" ]; then
            log "Using provided ASL and M0 NIfTI files"
            cp "$asl_zip" "${asl_dcm_dir}/"
            cp "$m0_input" "${asl_dcm_dir}/"
            asl_nifti="${asl_dcm_dir}/$(basename "$asl_zip")"
            m0_nifti="${asl_dcm_dir}/$(basename "$m0_input")"
            log "ASL file: ${asl_nifti}"
            log "M0 file: ${m0_nifti}"
        else
            die "NIfTI input requires both ASL and M0 files. Provide M0 via -m flag or nifti_m0 input."
        fi
    elif file "$asl_zip" | grep -q 'Zip archive data'; then
        # DICOM zip
        unzip -d "$asl_dcm_dir" "$asl_zip"
        dcm2niix -f %d -b y -o "${asl_dcm_dir}/" "$asl_dcm_dir"
        nifti_input=false
    else
        # Assume DICOM folder/file
        cp -r "$asl_zip" "${asl_dcm_dir}/"
        dcm2niix -f %d -b y -o "${asl_dcm_dir}/" "$asl_zip"
        nifti_input=false
    fi

    # For DICOM input, detect ASL vs M0 from converted files
    if [ "$nifti_input" = false ]; then
        # Collect NIfTI files
        shopt -s nullglob
        nifti_files=("${asl_dcm_dir}"/*.nii "${asl_dcm_dir}"/*.nii.gz)
        shopt -u nullglob

        log "Found ${#nifti_files[@]} NIfTI file(s) in ${asl_dcm_dir}"

        if (( ${#nifti_files[@]} < 2 )); then
            die "Expected at least 2 NIfTI files in ${asl_dcm_dir}, but found ${#nifti_files[@]}"
        fi

        vol0="${nifti_files[0]}"
        vol1="${nifti_files[1]}"
        log "File 1: ${vol0}"
        log "File 2: ${vol1}"

        # Determine which is ASL vs M0 based on max intensity
        max0=$(fslstats "${vol0}" -R | awk '{print $2}')
        max1=$(fslstats "${vol1}" -R | awk '{print $2}')

        if [ "$(echo "${max0} < ${max1}" | bc -l)" -eq 1 ]; then
            asl_nifti="${vol0}"
            m0_nifti="${vol1}"
        else
            asl_nifti="${vol1}"
            m0_nifti="${vol0}"
        fi
    fi

    # Get JSON sidecar file
    json_file="${asl_nifti%.nii.gz}.json"
    [ ! -f "${json_file}" ] && json_file="${asl_nifti%.nii}.json"

    if [ ! -f "${json_file}" ]; then
        if [ "$nifti_input" = true ]; then
            log "No JSON sidecar found for NIfTI input - parameters must be provided via config or command line"
            json_file=""
        else
            die "JSON file not found for ${asl_nifti}"
        fi
    else
        log "JSON file: ${json_file}"
    fi
}

# ==============================================================================
# PARAMETER EXTRACTION
# ==============================================================================

extract_parameters() {
    log "Extracting acquisition parameters"

    if ! is_valid_number "${avg_input:-}" || \
       ! is_valid_number "${ld_input:-}"  || \
       ! is_valid_number "${pld_input:-}"; then
        # Parse from JSON file
        num_avg=$(grep '"NumberOfAverages"' "${json_file}" | awk -F': ' '{print $2}' | tr -d ', ')
        m0_scale=$((num_avg * 32))
        ld=$(grep '"LabelingDuration"' "${json_file}" | awk -F': ' '{print $2}' | tr -d ', ')
        pld=$(grep '"PostLabelingDelay"' "${json_file}" | awk -F': ' '{print $2}' | tr -d ', ')
        log "Parsed from JSON file"
        log "NumberOfAverages: ${num_avg}, M0 Scale: ${m0_scale}"
        log "Labeling duration: ${ld}, Post labeling delay: ${pld}"
    else
        m0_scale=$((avg_input * 32))
        ld="$ld_input"
        pld="$pld_input"
        log "Parsed from Flywheel/Docker input"
        log "NumberOfAverages: ${avg_input}, M0 Scale: ${m0_scale}"
        log "Labeling duration: ${ld}, Post labeling delay: ${pld}"
    fi

    if [[ -z "${ld:-}" || -z "${pld:-}" || -z "${m0_scale:-}" ]]; then
        die "One or more required variables (ld, pld, m0_scale) are unset or empty"
    fi
}

# ==============================================================================
# SKULL STRIPPING
# ==============================================================================

skull_strip() {
    log "Performing skull stripping"
    "${FREESURFER_HOME}/bin/mri_synthstrip" -i "${m0_nifti}" -m "${work_dir}/mask.nii.gz"
    fslmaths "${work_dir}/mask.nii.gz" -ero "${work_dir}/mask_ero.nii.gz"
}

# ==============================================================================
# CBF CALCULATION
# ==============================================================================

calculate_cbf() {
    log "Calculating CBF"
    python3 /flywheel/v0/workflows/ge_cbf_calc.py \
        -m0 "${m0_nifti}" \
        -asl "${asl_nifti}" \
        -m "${work_dir}/mask.nii.gz" \
        -ld "$ld" \
        -pld "$pld" \
        -scale "$m0_scale" \
        -out "${work_dir}"

    fslmaths "${work_dir}/cbf.nii.gz" -mas "${work_dir}/mask_ero.nii.gz" "${work_dir}/cbf_mas.nii.gz"
}

# ==============================================================================
# IMAGE REGISTRATION
# ==============================================================================

register_to_template() {
    log "Registering to template space"

    # Smooth ASL image and register to template
    fslmaths "${work_dir}/asl_mc.nii.gz" -s 1.5 -mas "${work_dir}/mask.nii.gz" "${work_dir}/s_asl.nii.gz"

    "${ANTSPATH}/antsRegistration" \
        --dimensionality 3 \
        --transform "Affine[0.25]" \
        --metric "MI[${std_dir}/batsasl/bats_asl_masked.nii.gz,${work_dir}/s_asl.nii.gz,1,32]" \
        --convergence 100x20 \
        --shrink-factors 4x1 \
        --smoothing-sigmas 2x0mm \
        --transform "SyN[0.1]" \
        --metric "CC[${std_dir}/batsasl/bats_asl_masked.nii.gz,${work_dir}/s_asl.nii.gz,1,1]" \
        --convergence 40x20 \
        --shrink-factors 2x1 \
        --smoothing-sigmas 2x0mm \
        --output "[${work_dir}/ind2temp,${work_dir}/ind2temp_warped.nii.gz,${work_dir}/temp2ind_warped.nii.gz]" \
        --collapse-output-transforms 1 \
        --interpolation BSpline \
        -v 1

    log "ANTs Registration finished"

    # Warp template CBF to subject space
    "${ANTSPATH}/WarpImageMultiTransform" 3 \
        "${std_dir}/batsasl/bats_cbf.nii.gz" \
        "${work_dir}/w_batscbf.nii.gz" \
        -R "${work_dir}/asl_mc.nii.gz" \
        -i "${work_dir}/ind2temp0GenericAffine.mat" \
        "${work_dir}/ind2temp1InverseWarp.nii.gz"
}

# ==============================================================================
# ROI ANALYSIS
# ==============================================================================

process_roi() {
    local roi="$1"
    log "Processing ROI: ${roi}"

    touch "${stats_dir}/tmp_${roi}.txt"
    touch "${stats_dir}/cbf_${roi}.txt"
    touch "${stats_dir}/${roi}_vox.txt"

    # Warp ROI to subject space
    "${ANTSPATH}/WarpImageMultiTransform" 3 \
        "${std_dir}/${roi}.nii.gz" \
        "${work_dir}/w_${roi}.nii.gz" \
        -R "${work_dir}/asl_mc.nii.gz" \
        --use-NN \
        -i "${work_dir}/ind2temp0GenericAffine.mat" \
        "${work_dir}/ind2temp1InverseWarp.nii.gz"

    # Apply mask and extract statistics
    fslmaths "${work_dir}/w_${roi}.nii.gz" -mas "${work_dir}/mask_ero.nii.gz" "${work_dir}/w_${roi}_mas.nii.gz"
    fslstats -K "${work_dir}/w_${roi}_mas.nii.gz" "${work_dir}/cbf_mas.nii.gz" -M -S > "${stats_dir}/tmp_${roi}.txt"
    fslstats -K "${work_dir}/w_${roi}_mas.nii.gz" "${work_dir}/cbf_mas.nii.gz" -V > "${stats_dir}/${roi}_vox.txt"

    # Combine label with values
    paste "${std_dir}/${roi}_label.txt" -d ' ' "${stats_dir}/tmp_${roi}.txt" "${stats_dir}/${roi}_vox.txt" > "${stats_dir}/cbf_${roi}.txt"
}

format_roi_stats() {
    local roi="$1"
    local input_cbf="${stats_dir}/cbf_${roi}.txt"
    local output_cbf="${stats_dir}/formatted_cbf_${roi}.txt"
    local temp_dir="${work_dir}/temp_format_$$"
    mkdir -p "$temp_dir"

    local temp_file="$temp_dir/tmp_cbf_${roi}.txt"
    echo "Region | Mean CBF | Standard Deviation | Voxels | Volume" > "$temp_file"

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local mean_cbf std_dev voxels volume region
        mean_cbf=$(echo "$line" | awk '{print $(NF-3)}')
        std_dev=$(echo "$line" | awk '{print $(NF-2)}')
        voxels=$(echo "$line" | awk '{print $(NF-1)}')
        volume=$(echo "$line" | awk '{print $NF}')

        region=$(echo "$line" | awk '{
            for (i=1; i<=NF-4; i++) printf "%s ", $i;
        }' | sed 's/[[:space:]]$//')

        # Skip invalid entries
        [[ -z "$region" || "$region" == "0" || "$region" == *"missing label"* || "$voxels" -lt 10 ]] 2>/dev/null && continue

        printf "%s | %.1f | %.1f | %.1f | %.1f\n" \
            "$region" "$mean_cbf" "$std_dev" "$voxels" "$volume" >> "$temp_file"
    done < "$input_cbf"

    column -t -s '|' -o '|' "$temp_file" > "$output_cbf"
    rm -rf "$temp_dir"
}

run_roi_analysis() {
    log "Running ROI analysis"

    for roi in "${roi_list[@]}"; do
        process_roi "$roi"
    done

    for roi in "${roi_list[@]}"; do
        format_roi_stats "$roi"
    done
}

# ==============================================================================
# EXTRACT AD-RELATED REGIONS
# ==============================================================================

extract_ad_regions() {
    log "Extracting AD-related regions"

    local extracted_file="${stats_dir}/extracted_regions_combined.txt"
    echo "Region | Mean CBF | Standard Deviation | Voxels | Volume" > "$extracted_file"

    for type in cortical subcortical landau; do
        local source_file="${stats_dir}/formatted_cbf_${type}.txt"
        [[ -f "$source_file" ]] || continue

        while IFS= read -r line; do
            [[ "$line" == "Region |"* || -z "$line" ]] && continue

            local region
            region=$(echo "$line" | awk -F '|' '{print $1}' | xargs)

            for target in "${target_regions[@]}"; do
                if [[ "$region" == "$target" ]]; then
                    echo "$line" >> "$extracted_file"
                fi
            done
        done < "$source_file"
    done
}

# ==============================================================================
# WEIGHTED rCBF CALCULATIONS
# ==============================================================================

calculate_weighted_rcbf() {
    log "Calculating weighted rCBF values"

    local cortical="${stats_dir}/formatted_cbf_cortical.txt"
    local subcortical="${stats_dir}/formatted_cbf_subcortical.txt"
    local landau="${stats_dir}/formatted_cbf_landau.txt"

    # Extract region values and voxel counts
    local pcc pcc_voxel precuneus precuneus_voxel
    local hipp_left hipp_left_voxel hipp_right hipp_right_voxel
    local grey_left grey_left_vox grey_right grey_right_vox
    local white_left white_left_vox white_right white_right_vox
    local putamen_left putamen_left_vox putamen_right putamen_right_vox
    local landau_meta landau_meta_vox

    read -r pcc pcc_voxel <<< "$(extract_region_stats "$cortical" "Cingulate_Gyrus,_posterior_division")"
    read -r precuneus precuneus_voxel <<< "$(extract_region_stats "$cortical" "Precuneous_Cortex")"
    read -r hipp_left hipp_left_voxel <<< "$(extract_region_stats "$subcortical" "Left_Hippocampus")"
    read -r hipp_right hipp_right_voxel <<< "$(extract_region_stats "$subcortical" "Right_Hippocampus")"
    read -r grey_left grey_left_vox <<< "$(extract_region_stats "$subcortical" "Left_Cerebral_Cortex")"
    read -r grey_right grey_right_vox <<< "$(extract_region_stats "$subcortical" "Right_Cerebral_Cortex")"
    read -r white_left white_left_vox <<< "$(extract_region_stats "$subcortical" "Left_Cerebral_White_Matter")"
    read -r white_right white_right_vox <<< "$(extract_region_stats "$subcortical" "Right_Cerebral_White_Matter")"
    read -r putamen_left putamen_left_vox <<< "$(extract_region_stats "$subcortical" "Left_Putamen")"
    read -r putamen_right putamen_right_vox <<< "$(extract_region_stats "$subcortical" "Right_Putamen")"
    read -r landau_meta landau_meta_vox <<< "$(extract_region_stats "$landau" "Landau_metaROI")"

    # Calculate weighted averages
    local grey_matter_weighted white_matter_weighted whole_brain_weighted
    local putamen_weighted pcc_precuneus_weighted hippocampus_weighted

    grey_matter_weighted=$(calc_weighted_avg "$grey_left" "$grey_left_vox" "$grey_right" "$grey_right_vox")
    white_matter_weighted=$(calc_weighted_avg "$white_left" "$white_left_vox" "$white_right" "$white_right_vox")
    putamen_weighted=$(calc_weighted_avg "$putamen_left" "$putamen_left_vox" "$putamen_right" "$putamen_right_vox")
    pcc_precuneus_weighted=$(calc_weighted_avg "$pcc" "$pcc_voxel" "$precuneus" "$precuneus_voxel")
    hippocampus_weighted=$(calc_weighted_avg "$hipp_left" "$hipp_left_voxel" "$hipp_right" "$hipp_right_voxel")

    # Whole brain (grey + white matter)
    whole_brain_weighted=$(echo "scale=4; \
        ($grey_left * $grey_left_vox + $grey_right * $grey_right_vox + \
         $white_left * $white_left_vox + $white_right * $white_right_vox) / \
        ($grey_left_vox + $grey_right_vox + $white_left_vox + $white_right_vox)" | bc -l)

    log "Whole brain weighted CBF: $whole_brain_weighted"

    # Write weighted rCBF file
    local weighted_rcbf="${stats_dir}/weighted_rcbf.txt"
    echo "Region | CBF | Voxels" > "$weighted_rcbf"

    write_weighted_row() {
        local name="$1" value="$2" voxels="$3"
        if [[ -n "$value" && "$value" =~ ^[0-9.]+$ ]]; then
            echo "$name | $value | $voxels" >> "$weighted_rcbf"
        else
            log_error "$name CBF value is not a number"
        fi
    }

    local whole_brain_vox grey_matter_vox white_matter_vox pcc_precuneus_vox hipp_vox
    whole_brain_vox=$(echo "$grey_left_vox + $grey_right_vox + $white_left_vox + $white_right_vox" | bc -l)
    grey_matter_vox=$(echo "$grey_left_vox + $grey_right_vox" | bc -l)
    white_matter_vox=$(echo "$white_left_vox + $white_right_vox" | bc -l)
    pcc_precuneus_vox=$(echo "$pcc_voxel + $precuneus_voxel" | bc -l)
    hipp_vox=$(echo "$hipp_left_voxel + $hipp_right_voxel" | bc -l)

    write_weighted_row "Whole brain" "$whole_brain_weighted" "$whole_brain_vox"
    write_weighted_row "Grey_Matter L+R" "$grey_matter_weighted" "$grey_matter_vox"
    write_weighted_row "White_Matter L+R" "$white_matter_weighted" "$white_matter_vox"
    write_weighted_row "PCC+Precuneus" "$pcc_precuneus_weighted" "$pcc_precuneus_vox"
    write_weighted_row "Hippocampus L+R" "$hippocampus_weighted" "$hipp_vox"

    cat "$weighted_rcbf"

    # Calculate rCBF ratios relative to putamen
    local temp_file="${stats_dir}/temp_ratio_calc.txt"
    awk -F '|' -v put_cbf="$putamen_weighted" '
    BEGIN {
        OFS = " | "
        print "Region | Mean | rCBF | Voxels"
    }
    {
        if (NF < 3 || $0 ~ /^Region/) next
        mean = $2 + 0
        voxels = $3 + 0
        rcbf = (mean != 0) ? mean / put_cbf : "NA"
        printf "%s | %.0f | %.1f | %.0f\n", $1, mean, rcbf, voxels
    }' "$weighted_rcbf" | column -t -s '|' -o '|' > "$temp_file"

    mv "$temp_file" "${stats_dir}/weighted_table.txt"
}

# ==============================================================================
# VISUALIZATION
# ==============================================================================

create_visualizations() {
    log "Creating visualizations"

    # Smooth deformation field and warp images
    fslmaths "${work_dir}/ind2temp1Warp.nii.gz" -s 5 "${work_dir}/swarp.nii.gz"

    "${ANTSPATH}/WarpImageMultiTransform" 3 \
        "${asl_nifti}" \
        "${work_dir}/s_ind2temp_warped.nii.gz" \
        -R "${work_dir}/ind2temp_warped.nii.gz" \
        --use-BSpline \
        "${work_dir}/swarp.nii.gz" \
        "${work_dir}/ind2temp0GenericAffine.mat"

    "${ANTSPATH}/WarpImageMultiTransform" 3 \
        "${work_dir}/cbf.nii.gz" \
        "${work_dir}/wcbf.nii.gz" \
        -R "${work_dir}/ind2temp_warped.nii.gz" \
        --use-BSpline \
        "${work_dir}/swarp.nii.gz" \
        "${work_dir}/ind2temp0GenericAffine.mat"

    # Upsample to 1mm for visualization
    flirt -in "${work_dir}/cbf.nii.gz" -ref "${work_dir}/cbf.nii.gz" \
        -applyisoxfm 1.0 -nosearch -out "${work_dir}/cbf_1mm.nii.gz" -interp spline
    flirt -in "${work_dir}/mask.nii.gz" -ref "${work_dir}/mask.nii.gz" \
        -applyisoxfm 1.0 -nosearch -out "${work_dir}/mask_1mm.nii.gz"
    fslmaths "${work_dir}/cbf_1mm.nii.gz" -s 2 "${work_dir}/s_cbf_1mm.nii.gz"

    # Generate visualization images
    python3 /flywheel/v0/workflows/not1_viz.py \
        -cbf "${work_dir}/s_cbf_1mm.nii.gz" \
        -out "${viz_dir}/" \
        -seg_folder "${work_dir}/" \
        -seg "${viz_roi_list[@]}" \
        -mask "${work_dir}/mask_1mm.nii.gz"
}

# ==============================================================================
# PDF GENERATION
# ==============================================================================

generate_reports() {
    log "Generating PDF reports"

    python3 /flywheel/v0/workflows/not1_pdf.py \
        -viz "${viz_dir}" \
        -stats "${stats_dir}/" \
        -out "${work_dir}/" \
        -seg_folder "${work_dir}/" \
        -seg "${viz_roi_list[@]}"

    python3 /flywheel/v0/workflows/qc.py \
        -viz "${viz_dir}" \
        -out "${work_dir}" \
        -seg_folder "${work_dir}/" \
        -seg "${viz_roi_list[@]}"
}

# ==============================================================================
# OUTPUT PACKAGING
# ==============================================================================

package_outputs() {
    log "Packaging outputs"

    # Move CBF output to export directory
    mv "${work_dir}/cbf.nii.gz" "${export_dir}/" 2>/dev/null || true

    # Move extended analysis outputs if they exist
    if [ "$skip_extended" != "true" ]; then
        mv "${work_dir}/output.pdf" "${export_dir}/" 2>/dev/null || true
        mv "${work_dir}/qc.pdf" "${export_dir}/" 2>/dev/null || true
        mv "${export_dir}/stats/tmp"* "${work_dir}/" 2>/dev/null || true
    fi

    # Get subject ID for file naming
    local subject_id
    subject_id=$(grep "^Subject:" "${export_dir}/metadata.json" | cut -d' ' -f2- || echo "")

    if [ -z "$subject_id" ]; then
        log "Subject ID not found, using generic names"
        zip -q -r "${export_dir}/final_output.zip" "${export_dir}"
        zip -q -r "${export_dir}/work_dir.zip" "${work_dir}"
    else
        log "Subject ID: $subject_id"
        mv "${export_dir}/cbf.nii.gz" "${export_dir}/${subject_id}_cbf.nii.gz"
        if [ "$skip_extended" != "true" ]; then
            mv "${export_dir}/output.pdf" "${export_dir}/${subject_id}_output.pdf"
            mv "${export_dir}/qc.pdf" "${export_dir}/${subject_id}_qc.pdf"
        fi
        zip -q -r "${export_dir}/${subject_id}_final_output.zip" "${export_dir}"
        zip -q -r "${export_dir}/${subject_id}_work_dir.zip" "${work_dir}"
    fi
}

# ==============================================================================
# MAIN PIPELINE
# ==============================================================================

log "Starting GEASLscp pipeline"

extract_metadata
preprocess_data
extract_parameters
skull_strip
calculate_cbf

if [ "$skip_extended" != "true" ]; then
    register_to_template
    run_roi_analysis
    extract_ad_regions
    calculate_weighted_rcbf
    create_visualizations
    generate_reports
fi

package_outputs

log "Pipeline completed successfully"
