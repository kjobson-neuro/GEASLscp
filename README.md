# GE ASL Self-Contained Processing Docker Container (GEASLscp)

This GitHub repository contains a Docker container for processing GE Arterial Spin Labeling (ASL) MRI data without requiring a structural scan. The processing pipeline was developed at Penn Medicine by Manuel Taso. The Docker container and Flywheel gear were developed by Katie Jobson.

## Overview

This pipeline processes **GE 3D pCASL data** and computes cerebral blood flow (CBF) maps. A single input file is required containing both the ASL timeseries data and M0 calibration image.

### Processing Steps

1. **DICOM to NIfTI conversion** using dcm2niix
2. **Automatic ASL/M0 detection** based on signal intensity
3. **Skull stripping** using FreeSurfer's mri_synthstrip
4. **CBF quantification** using the standard kinetic model as reported in the White Paper (Alsop 2015)
5. **Registration to template space** using ANTs
6. **ROI-based analysis** with multiple brain atlases for Alzheimer's specific regions of interest
7. **PDF report generation** with QC images and regional CBF values

### Key Features

- Automatic extraction of acquisition parameters from JSON sidecar files
- Automatic differentiation of ASL and M0 volumes based on signal intensity
- Registration of standard atlases (arterial, cortical, subcortical, thalamus, Schaefer 2018, Landau metaROI)
- Extraction of mean CBF in Alzheimer's Disease-relevant regions
- Calculation of relative CBF (rCBF) normalized to putamen
- Weighted CBF calculations for composite regions (whole brain, grey matter, white matter)
- PDF output with QC visualizations and tabular results

### CBF Quantification Model

CBF is calculated using the standard kinetic model for pCASL as described in the ASL White Paper (Alsop et al., 2015):

$$
CBF = \frac{6000 \cdot \lambda \cdot \Delta M \cdot e^{PLD/T_{1b}}}{2 \cdot \alpha \cdot T_{1b} \cdot M_0 \cdot (1 - e^{-LD/T_{1b}})}
$$

Where:
- **ΔM** = ASL difference signal (control - label)
- **M0** = equilibrium magnetization (scaled by number of averages × 32)
- **LD** = labeling duration (seconds)
- **PLD** = post-labeling delay (seconds)

Fixed parameters:
| Parameter | Value | Description |
|-----------|-------|-------------|
| α | 0.6375 | Labeling efficiency for pCASL |
| λ | 0.9 mL/g | Blood–brain partition coefficient |
| T1b | 1.6 s | T1 of arterial blood at 3T |

CBF is output in units of mL/100g/min.

**Reference:** Alsop DC, et al. Recommended implementation of arterial spin-labeled perfusion MRI for clinical applications. *Magn Reson Med.* 2015;73(1):102-116.

**Disclaimer:** This CBF quantification does not replicate the automatic CBF calculation performed on the GE scanner console. Results may differ from scanner-generated CBF maps.

## Inputs

| Input | Description | Required |
|-------|-------------|----------|
| `dicom_nifti_asl` | DICOM zip containing ASL and M0, or ASL NIfTI file (.nii/.nii.gz) | Yes |
| `nifti_m0` | M0 NIfTI file. Required when using NIfTI input. | No (required for NIfTI) |

## Configuration Parameters

These parameters can be obtained in two ways:
1. **Auto-extracted from DICOM** - When using DICOM input, dcm2niix generates a JSON sidecar containing these values
2. **Manually provided** - Use command line flags (`-l`, `-p`, `-n`) or parsed from Flywheel

| Parameter | Description | Notes |
|-----------|-------------|-------|
| `ld` | Labeling duration (seconds) | Flag: `-l` |
| `pld` | Post-labeling delay (seconds) | Flag: `-p` |
| `avg` | Number of averages | Flag: `-n`. Used to calculate M0 scale factor (avg * 32) |
| `skip_extended` | Skip registration, atlas extraction, and PDF generation | Flag: `-e`. Default: false. When true, only outputs CBF map. |

If your DICOM sequence does not include the labeling duration, post-labeling delay, and number of averages in its headers, you will need to provide these parameters manually. For NIfTI input, these parameters are always required via JSON file, flags, or config.

## Outputs

| Output | Description |
|--------|-------------|
| `{subject_id}_cbf.nii.gz` | Quantitative CBF map |
| `{subject_id}_output.pdf` | PDF report with QC images and regional CBF tables |
| `{subject_id}_qc.pdf` | Quality control PDF |
| `stats/` | Directory containing regional CBF text files |
| `viz/` | Directory containing visualization images |
| `{subject_id}_final_output.zip` | Zipped output directory |
| `{subject_id}_work_dir.zip` | Zipped working directory with intermediate files |

If there is no subject ID supplied, or no subject ID present when you run this container as a Flywheel gear, the outputs will not include subject ID.

## Examples of Running the Docker Container

### Basic Usage

```bash
docker run -v /path/to/input:/flywheel/v0/input \
           -v /path/to/output:/flywheel/v0/output \
           kjobson/geaslscp:latest \
           -a /flywheel/v0/input/asl_dicom.zip
```

### With Manual Parameters

If your data does not contain the acquisition parameters in the JSON sidecar, provide them manually:

```bash
docker run -v /path/to/input:/flywheel/v0/input \
           -v /path/to/output:/flywheel/v0/output \
           kjobson/geaslscp:latest \
           -a /flywheel/v0/input/asl_dicom.zip \
           -l 1.8 \
           -p 2.0 \
           -n 4
```

### With NIfTI Input

For NIfTI input, provide both ASL and M0 files along with acquisition parameters:

```bash
docker run -v /path/to/input:/flywheel/v0/input \
           -v /path/to/output:/flywheel/v0/output \
           kjobson/geaslscp:latest \
           -a /flywheel/v0/input/asl.nii.gz \
           -m /flywheel/v0/input/m0.nii.gz \
           -l 1.8 \
           -p 2.0 \
           -n 4
```

### CBF Only (Skip Extended Analysis)

To output only the CBF map without registration, atlas extraction, or PDF generation:

```bash
docker run -v /path/to/input:/flywheel/v0/input \
           -v /path/to/output:/flywheel/v0/output \
           kjobson/geaslscp:latest \
           -a /flywheel/v0/input/asl_dicom.zip \
           -e
```

### Command Line Options

| Option | Description |
|--------|-------------|
| `-a` | Path to ASL DICOM zip or ASL NIfTI file |
| `-m` | Path to M0 NIfTI file (required when using NIfTI input) |
| `-l` | Labeling duration (seconds) |
| `-p` | Post-labeling delay (seconds) |
| `-n` | Number of averages |
| `-e` | Skip extended analysis (registration, atlas extraction, PDF) |
| `-s` | Subject ID |

## Examples of Uploading the Container as a Flywheel Gear

### Prerequisites

1. Install the Flywheel CLI: https://docs.flywheel.io/CLI/
2. Log in to your Flywheel instance: `fw login <your-api-key>`
3. Edit the manifest file to fit with your specifications - you may have to change your username in place of `kjobson`

### Building and Uploading

1. **Build the Docker image:**

```bash
fw-beta gear build .
```

2. **Test**

```bash
fw-beta gear run .
```

3. **Upload to Flywheel:**

```bash
fw-beta gear upload .
```

This command reads the `manifest.json` and uploads the gear to your Flywheel instance.

### Running on Flywheel

1. Navigate to your session containing ASL data
2. Select the ASL data file (containing both ASL timeseries and M0)
3. Click "Run Gear" and select "GEASLscp: GE Self-Contained Processing"
4. Configure parameters if needed (or leave blank for automatic extraction)
5. Run the analysis

## Software Dependencies

The container includes:

- **FreeSurfer 7.4.1** - skull stripping (mri_synthstrip)
- **FSL 6.0.7.1** - image math, registration tools
- **ANTs 2.5.4** - nonlinear registration
- **dcm2niix** - DICOM to NIfTI conversion
- **Python 3** with: scipy, nibabel, matplotlib, nilearn, reportlab

## Citation

If you use this pipeline, please cite the relevant software packages and acknowledge the developers.

## License

MIT License
