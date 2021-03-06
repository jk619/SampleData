## PREPROCESS DATA, including:
#   1. conversion to BIDS
#   2. Defacing
#   3. MRIQC
#   4. FMRIPrep

# Exit upon any error
set -exo pipefail


## Change lines for Study/subject/system. Also add lines for stim files, TSV fles, and eye tracking files. Then try running it on our sample data.
DIRN=`dirname $0`
source $DIRN/setup.sh

# Go!
# Sample data from subject wlsubj042, acquired on DATE!?!?!?!
#

###   Global variables:   ###

# Study/subject specific #
dcmFolder="$SAMPLE_DATA_DIR/dicoms"
logFolder=${LOG_DIR}/s1

mkdir -p $logFolder

# System specific #
# (These are the same for all studies/subjects):
# FreeSurfer license path:
#      We first check whether FREESURFER_LICENSE is an environmnetal variable
#      If not, we assume the path based on Mac OS organization
if [ -z "$FREESURFER_LICENSE" ]
then fsLicense=/Applications/freesurfer/license.txt
else fsLicense="$FREESURFER_LICENSE"
fi
[ -r "$fsLicense" ] || {
    echo "FreeSurfer license (${fsLicense}) not found!"
    echo "You can set a custom license path by storing it in the environment variable FREESURFER_LICENSE"
    exit 1
}
# we'll be running the Docker containers as yourself, not as root:
userID=$(id -u):$(id -g)


###   Get docker images:   ###
docker pull cbinyu/heudiconv:v3.2
docker pull bids/validator:1.4.3
docker pull cbinyu/bids_pydeface:v2.0.3
docker pull cbinyu/mriqc:0.15.0
docker pull poldracklab/fmriprep:1.4.1

# Also, download a couple of scripts used to fix or clean-up things:
curl -L -o ./completeJSONs.sh https://raw.githubusercontent.com/cbinyu/misc_preprocessing/4093899a359fb1307b2322584f2a6816482cbbd8/completeJSONs.sh
chmod 755 ./completeJSONs.sh

# Set up some derived variables that we'll use later:
fsLicenseBasename=$(basename $fsLicense)
fsLicenseFolder=${fsLicense%$fsLicenseBasename}

###   Extract DICOMs into BIDS:   ###
# The images were extracted and organized in BIDS format:
docker run --name heudiconv_container \
           --user $userID \
           --rm \
           --volume $dcmFolder:/dataIn:ro \
           --volume $STUDY_DIR:/dataOut \
           cbinyu/heudiconv:v3.2 \
               -d /dataIn/{subject}/*/*.dcm \
               -f cbi_heuristic \
               -s ${SUBJECT_ID} \
               -ss ${SESSION_ID} \
               -c dcm2niix \
               -b \
               -o /dataOut \
               --overwrite \
           > ${logFolder}/sub-${SUBJECT_ID}_extraction.log 2>&1    

# heudiconv makes files read only
#    We need some files to be writable, eg for defacing
chmod -R u+wr,g+wr ${STUDY_DIR}

# Then the 'IntendedFor' and 'NumberOfVolumes' field were filled:
./completeJSONs.sh ${STUDY_DIR}/sub-${SUBJECT_ID}/ses-${SESSION_ID}

## We run the BIDS-validator:

docker run --name BIDSvalidation_container \
           --user $userID \
           --rm \
           --volume $STUDY_DIR:/data:ro \
           bids/validator:1.4.3 \
               /data \
           > ${logFolder}/bids-validator_report.txt 2>&1                   
           # For BIDS compliance, we want the validator report to go to the top level of derivatives. But for debugging, we want all logs from a given script to go to a script-specific folder
           #> ${STUDY_DIR}/derivatives/bids-validator_report.txt 2>&1



###   Deface:   ###
# The anatomical images were defaced using PyDeface:
docker run --name deface_container \
           --user $userID \
           --rm \
           --volume $STUDY_DIR:/data \
           cbinyu/bids_pydeface:v2.0.3 \
               /data \
               /data/derivatives \
               participant \
               --participant_label ${SUBJECT_ID} \
           > ${logFolder}/sub-${SUBJECT_ID}_pydeface.log 2>&1

###   MRIQC:   ###
# mriqc_reports folder contains the reports generated by 'mriqc'
docker run --name mriqc_container \
           --user $userID \
           --rm \
           --volume $STUDY_DIR:/data \
           cbinyu/mriqc:0.15.0 \
               /data \
               /data/derivatives/mriqc_reports \
               participant \
               --ica \
               --verbose-reports \
               --fft-spikes-detector \
               --participant_label ${SUBJECT_ID} \
           > ${logFolder}/sub-${SUBJECT_ID}_mriqc_participant.log 2>&1
           
docker run --name mriqc_container \
           --user $userID \
           --rm \
           --volume $STUDY_DIR:/data \
           cbinyu/mriqc \
               /data \
               /data/derivatives/mriqc_reports \
               group \
           > ${logFolder}/sub-${SUBJECT_ID}_mriqc_group.log 2>&1

###   fMRIPrep:   ###
# fmriprep folder contains the reports and results of 'fmriprep'
docker run --name fmriprep_container \
           --user $userID \
           --rm \
           --volume $STUDY_DIR:/data \
           --volume ${fsLicenseFolder}:/FSLicenseFolder:ro \
           poldracklab/fmriprep:1.4.1 \
               /data \
               /data/derivatives \
               participant \
               --fs-license-file /FSLicenseFolder/$fsLicenseBasename \
               --output-space T1w fsnative template \
               --template-resampling-grid "native" \
               --t2s-coreg \
               --participant_label ${SUBJECT_ID} \
               --no-submm-recon \
           > ${logFolder}/sub-${SUBJECT_ID}_fMRIPrep.log 2>&1
