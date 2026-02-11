import sys
import os
import logging
import flywheel
import json
import glob
import shutil
from pathlib import Path
from datetime import datetime
import argparse

print(sys.path)

# get directory of metadata file
parser = argparse.ArgumentParser(description='get location of metadata file')
parser.add_argument('-dir',type=str, help='The directory where the metadata file is.')
args = parser.parse_args()

# logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger('geaslscp')
logger.info("=======: GE ASL gear :=======")

with flywheel.GearContext() as context:
    # Setup basic logging
    context.init_logging()
    config = context.config
    analysis_id = context.destination['id']
    
    # Set workdir for compatibility
    workdir = args.dir

    # Get relevant container objects
    fw = flywheel.Client(context.get_input('api_key')['key'])
    analysis_container = fw.get(analysis_id)
    project_container = fw.get(analysis_container.parents['project'])
    session_container = fw.get(analysis_container.parent['id'])
    subject_container = fw.get(session_container.parents['subject'])

    # Get subject, session, and project labels
    session_label = session_container.label
    subject_label = subject_container.label
    project_label = project_container.label
    
    # Get current runtime timestamp
    gear_run_datetime = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    
    # Get acquisition label - need to determine which acquisition this analysis belongs to
    acquisition_label = "Unknown"
    try:
        # If this is an acquisition-level analysis, get the acquisition
        if 'acquisition' in analysis_container.parent:
            acquisition_container = fw.get(analysis_container.parent['id'])
            acquisition_label = acquisition_container.label
        else:
            # If session-level analysis, you might want to get a specific acquisition
            # or list all acquisitions in the session
            acquisitions = session_container.acquisitions()
            if acquisitions:
                # Take the first acquisition or implement logic to select the right one
                acquisition_label = acquisitions[0].label
                logger.info(f"Multiple acquisitions found, using: {acquisition_label}")
    except Exception as e:
        logger.warning(f"Could not determine acquisition label: {e}")
        acquisition_label = "Unknown"

    subjects = [subject_container.label]
    sessions = [session_container.label]

    # Define the output file path
    INFO_OUT = os.path.join(workdir, "metadata.json")
    
    # Create metadata dictionary
    metadata = {
        "project_label": project_label,
        "subject_label": subject_label,
        "session_label": session_label,
        "acquisition_label": acquisition_label,
        "analysis_id": analysis_id,
        "gear_run_datetime": gear_run_datetime
    }
    
    # Write metadata to text file
    try:
        with open(INFO_OUT, 'w') as f:
            f.write("=== Flywheel Metadata ===\n")
            f.write(f"Project: {project_label}\n")
            f.write(f"Subject: {subject_label}\n")
            f.write(f"Session: {session_label}\n")
            f.write(f"Acquisition: {acquisition_label}\n")
            f.write(f"Analysis ID: {analysis_id}\n")
            f.write(f"Gear Run Date/Time: {gear_run_datetime}\n")
            f.write("========================\n")
            
            # Also write as JSON for machine readability
            f.write("\nJSON Format:\n")
            json.dump(metadata, f, indent=2)
            f.write("\n")
        
        logger.info(f"Metadata written to: {INFO_OUT}")
        logger.info(f"Metadata content: {metadata}")
        
    except Exception as e:
        logger.error(f"Failed to write metadata file: {e}")
        raise

