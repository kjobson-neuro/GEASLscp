import os
import argparse
from reportlab.lib.pagesizes import letter
from reportlab.platypus import SimpleDocTemplate, Table, TableStyle, Image, Paragraph, Spacer, PageBreak
from reportlab.lib import colors
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle

def read_formatted_file(file_path):
    try:
        with open(file_path, 'r') as file:
            content = file.read().strip().split('\n')
            data = []
            for line in content[1:]:  # Skip header line
                parts = line.split('|')
                parts = [p.strip() for p in parts]
                if len(parts) == 4:
                    region, mean_cbf, rcbf, vox = parts
                    data.append((region, mean_cbf, rcbf, vox))
                elif len(parts) == 5:
                    region, mean_cbf, std_dev, vox, vol = parts
                    data.append((region, mean_cbf, std_dev, vox, vol))
            return data
    except FileNotFoundError:
        return []

def generate_pdf(formatted_data, segmentation_images, output_path, mean_cbf_img=None, mean_cbf_bw_img=None, qt1_img=None, stats_path=None):
    doc = SimpleDocTemplate(output_path, pagesize=letter)
    elements = []
    styles = getSampleStyleSheet()

    

    # Style: wrapped title for long strings
    title_style = ParagraphStyle('TitleWrap', parent=styles['Title'], wordWrap='CJK')
    # Style: table header with wrapping
    header_style = ParagraphStyle('TableHeaderWrap', parent=styles['BodyText'], fontName='Helvetica-Bold', alignment=1, wordWrap='CJK')
# Add main title
    elements.append(Paragraph("ASL self-contained processing pipeline output", title_style))
    elements.append(Spacer(1, 24))

    
    # === Injected block: metadata under the title ===
    # Tries to read "metadata.txt" from the same directory as the output PDF.
    # Each line should be in "Key: Value" format.
    try:
        meta_file = os.path.join(os.path.dirname(output_path), "metadata.txt")
        if os.path.exists(meta_file):
            with open(meta_file, "r") as _mf:
                _lines = [ln.strip() for ln in _mf.read().strip().splitlines() if ln.strip()]
            _rows = []
            for _ln in _lines:
                if ":" in _ln:
                    _k, _v = _ln.split(":", 1)
                else:
                    _k, _v = _ln, ""
                # Bold the key (name), include a colon between key and value
                _para = Paragraph(f"<b>{_k.strip()}</b>: {_v.strip()}", styles["BodyText"])
                _rows.append([_para])
            # Single-column bordered panel
            _table = Table(_rows, hAlign="LEFT")
            _table.setStyle(TableStyle([
            ('ALIGN', (0,0), (0,-1), 'LEFT'),
            ("FONTNAME", (0,0), (-1,-1), "Helvetica"),
                ("FONTSIZE", (0,0), (-1,-1), 10),
                ("LEADING", (0,0), (-1,-1), 12),
                ("LEFTPADDING", (0,0), (-1,-1), 8),
                ("RIGHTPADDING", (0,0), (-1,-1), 8),
                ("TOPPADDING", (0,0), (-1,-1), 6),
                ("BOTTOMPADDING", (0,0), (-1,-1), 6),
                ("BOX", (0,0), (-1,-1), 0.75, colors.grey),
                ("BACKGROUND", (0,0), (-1,-1), colors.whitesmoke),
            ]))
            elements.append(_table)
            elements.append(Spacer(1, 18))
    except Exception as _e:
        # Fail silently to preserve original behavior
        pass
    # === End injected block ===
# Add mean_CBF and qT1 images if provided
    if mean_cbf_img and os.path.exists(mean_cbf_img):
        elements.append(Paragraph("Mean CBF", styles['Heading2']))
        elements.append(Image(mean_cbf_img, width=400, height=157))
        elements.append(Spacer(1, 12))

    if mean_cbf_bw_img and os.path.exists(mean_cbf_bw_img):
        elements.append(Paragraph("Mean CBF", styles['Heading2']))
        elements.append(Image(mean_cbf_bw_img, width=400, height=157))
        elements.append(Spacer(1, 12))

    # Add extracted regions section (after qT1, before segmentation)
    weighted_path = os.path.join(stats_path, 'weighted_table.txt')
    weighted_data = read_formatted_file(weighted_path)
    if weighted_data:
        elements.append(PageBreak())
        elements.append(Paragraph("CBF and rCBF values for AD Regions", styles['Heading2']))
        elements.append(Spacer(1, 12))
        # Build a compact, wrapped table that fits the page better
        table_data = [[
            Paragraph('Region', header_style),
            Paragraph('Mean CBF (mL/100g/min)', header_style),
            Paragraph('rCBF', header_style),
            Paragraph('Voxels (count)', header_style)
        ]]
        for region, mean, rcbf, voxels in weighted_data:
            table_data.append([Paragraph(str(region), styles['BodyText']), mean, rcbf, voxels])
        table = Table(table_data, repeatRows=1)
        table.setStyle(TableStyle([
            ('ALIGN', (0,0), (0,-1), 'LEFT'),
            ('BACKGROUND', (0,0), (-1,0), colors.lightgrey),
            ('TEXTCOLOR', (0,0), (-1,0), colors.black),
            ('ALIGN', (0,0), (-1,-1), 'CENTER'),
            ('FONTNAME', (0,0), (-1,0), 'Helvetica-Bold'),
            ('BOTTOMPADDING', (0,0), (-1,0), 12),
            ('GRID', (0,0), (-1,-1), 1, colors.black),
        ]))
        elements.append(table)
    
        elements.append(Spacer(1, 36))

    # Add segmentation tables, each on a new page
    for idx, (prefix, data) in enumerate(formatted_data.items()):
        if idx != 0:
            elements.append(PageBreak())
        elements.append(Paragraph(f"{prefix.capitalize()} CBF values extracted from segmentations", styles['Heading2']))
        elements.append(Spacer(1, 12))

        seg_img_path = segmentation_images.get(prefix, "")
        if seg_img_path and os.path.exists(seg_img_path):
            elements.append(Image(seg_img_path, width=400, height=200))
            elements.append(Spacer(1, 12))

        table_data = [[
            Paragraph('Region', header_style),
            Paragraph('Mean CBF (mL/100g/min)', header_style),
            Paragraph('Standard Deviation', header_style),
            Paragraph('Voxels (count)', header_style),
            Paragraph('Volume (mm^3)', header_style)
        ]]
        for region, mean_cbf, std_dev, vox, vol in data:
            table_data.append([Paragraph(str(region), styles['BodyText']), mean_cbf, std_dev, vox, vol])

        _w = doc.width if hasattr(doc, "width") else 468
        _c0 = int(_w * 0.38)
        _c1 = int(_w * 0.19)
        _c2 = int(_w * 0.19)
        _c3 = int(_w * 0.12)
        _c4 = _w - (_c0 + _c1 + _c2 + _c3)
        table = Table(table_data, colWidths=[_c0, _c1, _c2, _c3, _c4], repeatRows=1)
        table.setStyle(TableStyle([
            ('BACKGROUND', (0,0), (-1,0), colors.lightgrey),
            ('TEXTCOLOR', (0,0), (-1,0), colors.black),
            ('ALIGN', (0,0), (-1,-1), 'CENTER'),
            ('FONTNAME', (0,0), (-1,0), 'Helvetica-Bold'),
            ('BOTTOMPADDING', (0,0), (-1,0), 8),
            ('GRID', (0,0), (-1,-1), 1, colors.black),
        ]))
        elements.append(table)

        elements.append(Spacer(1, 24))

    doc.build(elements)
    print(f"PDF generated and saved at {output_path}")

def main():
    parser = argparse.ArgumentParser(description='Create PDF file to evaluate pipeline outputs.')
    parser.add_argument('-viz', type=str, help="The path to the viz folder.")
    parser.add_argument('-stats', type=str, help="The path to the stats folder.")
    parser.add_argument('-out', type=str, help="The output path.")
    parser.add_argument('-seg_folder', type=str, help="The path to the segmentation files.")
    parser.add_argument('-seg', type=str, nargs='+', help="The list of segmentations to display.")
    args = parser.parse_args()

    viz_path = args.viz
    stats_path = args.stats
    seg_folder = args.seg_folder
    seg_list = args.seg
    outputdir = args.out

    formatted_data = {}
    segmentation_images = {}

    for i in seg_list:
        file_path = os.path.join(stats_path, f"formatted_cbf_{i}.txt")
        seg_img = os.path.join(viz_path, f"w_{i}_meanCBF_80_mosaic_prism.png")
        if os.path.exists(file_path):
            data = read_formatted_file(file_path)
            if data:
                formatted_data[i] = data
            segmentation_images[i] = seg_img

    pdf_path = os.path.join(outputdir, 'output.pdf')
    mean_cbf_img = os.path.join(viz_path, "meanCBF_mosaic.png")
    mean_cbf_bw_img = os.path.join(viz_path, "meanCBF_bw.png")
    qt1_img = os.path.join(viz_path, "qT1_mosaic.png")

    generate_pdf(
        formatted_data,
        segmentation_images,
        pdf_path,
        mean_cbf_img=mean_cbf_img,
        mean_cbf_bw_img=mean_cbf_bw_img,
        qt1_img=qt1_img,
        stats_path=stats_path
    )

if __name__ == "__main__":
    main()
