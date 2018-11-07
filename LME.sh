#!/bin/bash

# Landmark nadir export and depth corrector
#
# Written by Stefano Nerozzi, last edit 17-Oct-2017 [stefano.nerozzi@utexas.edu]
# with critical help from Michael Christoffersen
#
# To run this script:
# ./LME.sh -i <LM .dat file> -n <arbitrary name for export> -c <number of cpu>
#
# Read instruction file for detailed explanations

in_dir=$MARS/orig/xtra/MRO1/PIK/lme
out_dir=$MARS/targ/xtra/MRO1/PIK/lme
treg_dir=/disk/qnap-2/MARS/targ/treg/MRO1/FPB201_sn #For now use sober SHARAD NAVs obtained via pixlatlon files

if [ ! ${1} ]; then
    echo "Usage: ./LME.sh -i <LM .dat file> -n <project name> -c <number of cpus>"
    exit 0
fi

while getopts ":i:n:c:" opt; do
    case $opt in
        i)
          infile="${in_dir}/$OPTARG"
          ;;
        n)
          dirname="$OPTARG" #add username+todays date as default
          ;;
        c)
          ncpu="$OPTARG"
          ;;
        \?)
		  echo "You didn't read/follow the instructions."
          echo "Usage: ./LME.sh -i <LM .dat file> -n <arbitrary name for export> -c <number of cpus>"
          exit 1
          ;;
    esac
done 

#Check things with user before making disasters
echo
echo "Landmark Export (LME) by Stefano Nerozzi"
echo
echo "Your file is: ${infile}"
echo "Your output will be in: ${out_dir}/${dirname}/"
echo "You want to use ${ncpu} cpu threads"
echo
read -p "Before proceeding, is this correct? [Y/n] " -r
if [[ $REPLY =~ ^[Nn]$ ]]; then
    echo "Fucking bananas!"
    exit
fi

#Create ram disk and project directories if they don't exist, ram disk speeds up things significantly
#Then create the temporary project directory and go there
ramdisk=/dev/shm/LME_RAMDISK
proj_dir="${ramdisk}/${dirname}"
if [ -d "${ramdisk}/${dirname}" ] || [ -d "${out_dir}/${dirname}" ]; then
    echo "Uh oh! A temporary or output directory already exists. Quitting."
    echo "Check (and remove, if necessary) the following directories:"
    echo "Temporary directory: ${ramdisk}/${dirname}/"
    echo "Output directory: ${out_dir}/${dirname}/"
    exit
fi
mkdir -p ${proj_dir}
cd ${proj_dir}

#Read horizon names and ask user if ok
echo
echo "Reading horizon names..."
echo
grep Horizon_name ${infile} | cut -d ' ' -f 2 | tee ${proj_dir}/horizon_list.temp

echo
read -p "Are these ALL your horizons? [Y/n] " -r
if [[ $REPLY =~ ^[Nn]$ ]]; then
    rm -rf ${proj_dir}
    echo "Fucking bananas!"
    exit
fi

#Ask user to write surface horizon name
echo
echo "Ok. Please write surface horizone name, it must be one of the above."
read -r
surf_hor=${REPLY}

#Ask which DEM to use, one option is a user-provided DEM
echo
echo "DEMs for depth conversion:"
echo "1) MOLA 128ppd, global coverage"
echo "2) MOLA 256ppd, Planum Boreum (large coverage)"
echo "3) MOLA 512ppd, Planum Boreum (small coverage)"
echo "4) Other DEM, please make sure you followed the instructions to make the geotiff."
echo
read -p "Which DEM do you want to use? [1,2,3 or 4] " -r
case "$REPLY" in
    1)
        DEMfile="/disk/qnap-2/MARS/orig/supl/MOLA/DEM_geotiffs/mola128_88Nto88S_Simp_clon0/mola128_oc0.tif"
    ;;
    2)
        DEMfile="/disk/qnap-2/MARS/orig/supl/MOLA/DEM_geotiffs/megt_n_256_1/megt_n_256_1.tif"
    ;;
    3)
        DEMfile="/disk/qnap-2/MARS/orig/supl/MOLA/DEM_geotiffs/megt512pd_wCap_ESRIgrids/megt_n_512mrg.tif"
    ;;
    4)
        echo
		read -p "Ok. Please write FULL PATH to your geotiff DEM file." -r
        echo
        DEMfile=${REPLY}
    ;;
esac

#Specify the datum used for the longitude-latitude pair. Also copy it in the project folder.
#Normally this is IAU Mars2000, but this may change with new products. Store this file under data/ in the script folder.
PRJfile="/disk/qnap-2/MARS/code/xtra/MRO1/PIK/lme/data/Mars2000.prj"
cp ${PRJfile} ${proj_dir}/

#Ask user what dielectric constant they want to use
echo
read -p "Please provide a dielectric constant for depth conversion (e.g. 3.10 for NPLD ice): " -r
echo
constant=`bc <<< "scale=10; 0.299792458/(2*sqrt(${REPLY}))"`

#Copy the DEM inside the ram disk to speed up GDAL when reading and update its path
cp ${DEMfile} ${proj_dir}
DEMfile=$(find ${proj_dir} -type f -name "*.tif")

#Preprocess by creating one temp folder for each profile, inside one temp file for each horizon
#LM .dat file data is in the format:
#line_name                            sample   TWT
#mro1_fpb_0933202000                  801.00   9914.17285
#temporary horizon files are in the format:
#string_line_name integer_sample string_TWT
#mro1_fpb_0933202000 8010 9914.17285
echo "Organising data, please wait..."
grep mro1_fpb_ ${infile} | cut -d ' ' -f 1 | sort -u > ${proj_dir}/line_list.temp #temp list of profile names
while read profile; do
    mkdir ${proj_dir}/${profile} #creates profile directories
    orbit=$(echo "${profile}" | cut -d '_' -f 3 | sed 's/^0*//')
    if [ -a "${treg_dir}/${orbit}/NAV_MROa/ztim_llz.bin" ]; then
        zvert ${treg_dir}/${orbit}/NAV_MROa/ztim_llz.bin | awk '{printf "%s %s\n", $4, $5}' > ${proj_dir}/${profile}/lonlat.temp
        echo "${profile}" >> ${proj_dir}/line_list_filtered.temp #Use this list next, otherwise will get many errors for missing nav files
    else
        echo "nav data missing, this profile will be skipped: ${profile}"
        echo "${profile}" >> ${proj_dir}/line_list_delete.temp #List of folders to delete
    fi
done < ${proj_dir}/line_list.temp
#This reads the source .dat file and saves to a temporary file rearranging some fields as described above
awk '/^#Horizon_name/{horizon=$2}; /^mro1_/{printf "%s %s %i %s\n", horizon, $1, $2, $3}' $infile >> ${proj_dir}/bigfile.temp

echo
read -p "Need to edit line_list?" -r
if [[ $REPLY =~ ^[NnYy]$ ]]; then
     echo "Fucking bananas!"
     echo
fi



#Call external c executable to organise files, bash was simple but too slow
/disk/qnap-2/MARS/code/xtra/MRO1/PIK/lme/bin/file_organiser bigfile.temp
rm -f bigfile.temp #don't need anymore

#Delete profile folders with no nav data
while read deletethis; do
    rm -rf ${proj_dir}/${deletethis}
done < ${proj_dir}/line_list_delete.temp

#Create final output files with headers, Arc usually selects them automatically when importing the data
while read out_file; do
    echo "lon lat elev TWT(ns) TWT(LM) orbit trace sample" > ${proj_dir}/${out_file}.txt
done < horizon_list.temp

#The prefix right now is fixed. Will need to change in the future if other products are added.
prefix="mro1_fpb_"
#Same with sample duration, will change as needed for different products
sample_t="37.5"

#Call another script to process each orbit folder in parallel, using parallel GNU
echo
echo "Starting ${ncpu} parallel jobs..."
#Call GNU Parallel. :::: reads a file as argument, ::: specifies the argument
/usr/local/parallel/bin/parallel -j ${ncpu} --no-notice /disk/qnap-2/MARS/code/xtra/MRO1/PIK/lme/bin/process_profile.sh :::: line_list_filtered.temp ::: ${prefix} ::: ${surf_hor} ::: ${PRJfile} ::: ${DEMfile} ::: ${constant} ::: ${sample_t}

#Delete temporary files
rm -f ${proj_dir}/*.temp
rm -f ${proj_dir}/*.tif

#Move final output to permament directory in the hierarchy
mv ${proj_dir} ${out_dir}/

#Delete ram disk
#rm -rf ${ramdisk}

#Reminder to user
echo "All done! Your data is in: ${out_dir}/${dirname}/"
