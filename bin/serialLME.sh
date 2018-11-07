#!/bin/bash

# Landmark nadir export and depth corrector - SERIAL VERSION
#
# Written by Stefano Nerozzi, last edit 30-Sep-2017 [stefano.nerozzi@utexas.edu]
# with critical help from Michael Christoffersen
#
# To run this script:
# ./LME.sh -i <LM .dat file> -n <arbitrary name for export> -c <number of cpu>
#
# Read instruction file for detailed explanations

out_dir=$MARS/orig/xtra/MRO1/PIK/lme
treg_dir=/disk/qnap-2/MARS/targ/treg/MRO1/FPB201

if [ ! ${1} ]; then
    echo "Usage: ./LME.sh -i <LM .dat file> -n <project name> -c <number of cpus>"
    exit 0
fi

while getopts ":i:n:c:" opt; do
    case $opt in
        i)
          infile="${out_dir}/$OPTARG"
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
echo "Your file is: ${out_dir}/${infile}"
echo "Your output will be in: ${out_dir}/${dirname}"
echo "You want to use ${ncpu} cpu threads"
echo
read -p "Before proceeding, is this correct? [y/n] " -r
if [[ $REPLY =~ ^[Nn]$ ]]; then
    exit
fi

#Create a ram disk, speeds up things a lot
ramdisk=/dev/shm/LME_RAMDISK
mkdir ${ramdisk}

#Create the temporary project directory and go there
proj_dir="${ramdisk}/${dirname}"
mkdir ${proj_dir}
cd ${proj_dir}

#Read horizon names and ask user if ok
echo
echo "Reading horizon names..."
echo
grep Horizon_name ${infile} | cut -d ' ' -f 2 | tee ${proj_dir}/horizon_list.tmp

echo
read -p "Are these ALL your horizons? [y/n] " -r
if [[ $REPLY =~ ^[Nn]$ ]]; then
    rm -rf ${proj_dir}
    exit
fi

#Preprocess by creating one temp folder for each profile, inside one temp file for each horizon
#LM .dat file data is in the format:
#line_name                            sample   TWT
#mro1_fpb_0933202000                  801.00   9914.17285
#temporary horizon files are in the format:
#string_line_name integer_sample string_TWT
#mro1_fpb_0933202000 8010 9914.17285

echo
echo "Organising data, please wait..."

grep mro1_fpb_ ${infile} | cut -d ' ' -f 1 | sort -u > ${proj_dir}/line_list.temp #temp list of profile names
while read profile; do
    mkdir ${proj_dir}/${profile} #creates profile directories
    orbit=$(echo "${profile}" | cut -d '_' -f 3 | sed 's/^0*//')
    zvert ${treg_dir}/${orbit}/NAV_MROa/ztim_llz.bin | awk '{printf "%s %s\n", $4, $5}' > ${proj_dir}/${profile}/lonlat.temp
done < ${proj_dir}/line_list.temp

awk '/^#Horizon_name/{horizon=$2}; /^mro1_/{printf "%s %s %i %s\n", horizon, $1, $2, $3}' $infile >> ${proj_dir}/bigfile.temp

#Call external c executable to organise files, bash was simple but too slow
echo "This may take several minutes..."
$MARS/code/modl/MRO/LME/bin/file_organiser bigfile.temp
rm -f bigfile.temp #don't need anymore

#Ask user to write surface horizon name
echo
echo "Ok. Please write surface horizone name."
read -r
surf_hor=${REPLY}

#Ask which DEM to use, one option is a user-provided DEM
echo
echo "Several surface DEMs can be used for depth conversion, these are the options:"
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

#Specify the datum used for the longitude-latitude pair.
#Normally this is IAU Mars2000, but this may change with new products. Store this file under data/ in the script folder.
PRJfile="/disk/qnap-2/MARS/code/modl/MRO/LME/data/Mars2000.prj"

#Copy the DEM inside the ram disk and update its path
cp ${DEMfile} ${ramdisk}
DEMfile=$(find ${ramdisk} -type f -name "*.tif")

#Ask user what dielectric constant they want to use
echo
read -p "Please provide a dielectric constant for depth conversion (e.g. 3.10 for NPLD ice): " -r
echo
constant=`bc <<< "scale=10; 0.299792458/(2*sqrt(${REPLY}))"`

#The prefix right now is fixed. Will need to change in the future if other products are added.
prefix="mro1_fpb_"

while read profile; do

echo ${profile}

cd ${proj_dir}/${profile} #profile is in the format mro1_fpb_0XXXXXX
orbit=${profile#$prefix} #removes prefix from profile
orbit=$((10#$orbit)) #removes leading zeros

#first we need to match the surface with a DEM, if surface exists exist
if [ -a "${surf_hor}.tmp" ]; then
	while read point; do #variable $point contains the nth line of the surface file being read
		trace=$(echo ${point} | cut -d ' ' -f 1)
		twt_lm=$(echo ${point} | cut -d ' ' -f 2)
		twt_ns=$(bc <<< "scale=1; (${twt_lm})*10")
		lonlat=$(sed "${trace}q;d" lonlat.temp) #extract lon and lat from nth line of file lonlat.temp
		elev=$(gdallocationinfo -valonly -l_srs "${PRJfile}" ${DEMfile} ${lonlat})
		if [ -z "${elev}" ]; then
			elev="null"
		fi
		echo "${lonlat} ${elev} ${twt_ns} ${twt_lm} ${orbit} ${trace}" >> "${surf_hor}.loc"
	done < ${surf_hor}.tmp
	rm -f ${surf_hor}.tmp #remove the old surface temp, now useless
	cat ${surf_hor}.loc >> ${proj_dir}/${surf_hor} # writes surface horizon data in final file
fi

#now need to process all the other horizons
ls | grep .tmp | cut -d '.' -f 1 > "list.temp"
while read horizon; do #variable $horizon contains the name of the horizon being read
	while read point; do #variable $point contains the nth line of the horizon file being read
		trace=$(echo ${point} | cut -d ' ' -f 1)
		twt_lm=$(echo ${point} | cut -d ' ' -f 2)
		twt_ns=$(bc <<< "scale=1; (${twt_lm})*10")
		lonlat=$(awk -v n=${trace} 'NR == n' lonlat.temp)
		elev="null" #this is replaced by a value if a surface pick exists for the current trace
		if [ -a "${surf_hor}.loc" ]; then
			surf_line=$(awk -v trace=${trace} '$7 == trace' ${surf_hor}.loc)
			if [ -n "${surf_line}" ]; then
				surf_elev=$(echo ${surf_line} | cut -d ' ' -f 3)
				surf_twt=$(echo ${surf_line} | cut -d ' ' -f 4)
				if [ "${surf_elev}" == "null" ]; then
					elev="null"
                else
				    elev=$(bc <<< "scale=3; ${surf_elev}-${constant}*(${twt_ns}-${surf_twt})")
                fi
			fi
		fi
		echo "${lonlat} ${elev} ${twt_ns} ${twt_lm} ${orbit} ${trace}" >> "${horizon}.loc"
	done < ${horizon}.tmp
	cat ${horizon}.loc >> ${proj_dir}/${horizon} # writes horizon data in final file
done < list.temp

#Everything should be done now, can delete this orbit folder
echo "Done processing ${profile}"
rm -rf ${proj_dir}/${profile}

done < line_list.temp

#Delete temporary files
rm -f ${proj_dir}/*.temp

#Move final output to permament directory in the hierarchy
mv ${proj_dir} ${out_dir}/

#Delete ram disk
rm -rf ${ramdisk}
