import os
import argparse
from reportlab.lib.pagesizes import letter
from reportlab.platypus import SimpleDocTemplate, Image, Paragraph, Spacer, PageBreak
from reportlab.lib.styles import getSampleStyleSheet

def generate_pdf(segmentation_images, output_path, mean_cbf_bw_img=None):
    doc = SimpleDocTemplate(output_path, pagesize=letter)
    elements = []
    styles = getSampleStyleSheet()

    # Add main title
    elements.append(Paragraph("ASL self-contained processing QC", styles['Title']))
    elements.append(Spacer(1, 24))

    # Add mean_CBF image if provided
    if mean_cbf_bw_img and os.path.exists(mean_cbf_bw_img):
        elements.append(Paragraph("Mean CBF", styles['Heading2']))
        elements.append(Image(mean_cbf_bw_img, width=400, height=157))
        elements.append(Spacer(1, 12))

    # Add segmentation images
    for seg_name in segmentation_images:
        seg_img_path = segmentation_images[seg_name]
        if seg_img_path and os.path.exists(seg_img_path):
            elements.append(Paragraph(f"Segmentation: {seg_name}", styles['Heading2']))
            elements.append(Image(seg_img_path, width=400, height=200))
            elements.append(Spacer(1, 12))

    # Remove the last PageBreak if present
    if elements and isinstance(elements[-1], PageBreak):
        elements = elements[:-1]

    doc.build(elements)
    print(f"PDF generated and saved at {output_path}")

def main():
    parser = argparse.ArgumentParser(description='Create PDF file to evaluate pipeline outputs.')
    parser.add_argument('-viz', type=str, help="The path to the viz folder.")
    parser.add_argument('-out', type=str, help="The output path.")
    parser.add_argument('-seg_folder', type=str, help="The path to the segmentation files.")
    parser.add_argument('-seg', type=str, nargs='+', help="The list of segmentations to display.")
    args = parser.parse_args()

    viz_path = args.viz
    seg_folder = args.seg_folder
    seg_list = args.seg
    outputdir = args.out

    segmentation_images = {}
    for i in seg_list:
        seg_img = os.path.join(viz_path, f"w_{i}_meanCBF_80_mosaic_prism.png")
        if os.path.exists(seg_img):
            segmentation_images[i] = seg_img

    pdf_path = os.path.join(outputdir, 'qc.pdf')
    mean_cbf_bw_img = os.path.join(viz_path, "meanCBF_bw.png")
    generate_pdf(segmentation_images, pdf_path, mean_cbf_bw_img=mean_cbf_bw_img)

if __name__ == "__main__":
    main()
