#!/bin/bash

# Process picks for a single profile
#
# Written by Stefano Nerozzi, last edit 13-Oct-2017 [stefano.nerozzi@utexas.edu]
# 
# This script is run in parallel with GNU Parallel, called by the main LME script
# Requires arguments, see variable assignment below
#
# Read instruction file for detailed explanations

#assign arguments to variables
profile=$1
prefix=$2
surf_hor=$3
PRJfile=$4
DEMfile=$5
constant=$6
sample_t=$7

cd ${profile} #profile is in the format mro1_fpb_0XXXXXX
orbit=${profile#$prefix} #removes prefix from profile
orbit=$((10#$orbit)) #removes leading zeros

#first we need to match the surface with a DEM, if surface exists exist
if [ -a "${surf_hor}.tmp" ]; then
	while read point; do #variable $point contains the nth line of the surface file being read
		trace=$(echo ${point} | cut -d ' ' -f 1)
		twt_lm=$(echo ${point} | cut -d ' ' -f 2)
		twt_ns=$(bc <<< "${twt_lm}*10") #10 is the conversion factor to go from LM units to nanoseconds
		lonlat=$(sed "${trace}q;d" lonlat.temp) #extract lon and lat from nth line of file lonlat.temp
        sample_n=$(bc <<< "${twt_ns}/${sample_t}") #sample number is real TWT in ns divided by sample duration in ns
        sample_n=$(printf "%.0f" ${sample_n}) #needs rounding, couldn't find a nicer way to do this
		elev=$(gdallocationinfo -valonly -l_srs "${PRJfile}" ${DEMfile} ${lonlat})
        elev=$(printf "%.3f" ${elev})
		if [ -z "${elev}" ]; then
			elev="nan"
		fi
		echo "${lonlat} ${elev} ${twt_ns} ${twt_lm} ${orbit} ${trace} ${sample_n}" >> "${surf_hor}.loc"
	done < ${surf_hor}.tmp
	rm -f ${surf_hor}.tmp #remove the old surface temp, now useless
	cat ${surf_hor}.loc >> ../${surf_hor}.txt # writes surface horizon data in final file
fi

#now need to process all the other horizons
ls | grep .tmp | cut -d '.' -f 1 > "list.temp"
while read horizon; do #variable $horizon contains the name of the horizon being read
	while read point; do #variable $point contains the nth line of the horizon file being read
		trace=$(echo ${point} | cut -d ' ' -f 1)
		twt_lm=$(echo ${point} | cut -d ' ' -f 2)
		twt_ns=$(bc <<< "${twt_lm}*10")
		lonlat=$(awk -v n=${trace} 'NR == n' lonlat.temp) #import trace as n, and goes to nth line assuming trace starts at 1
        sample_n=$(bc <<< "${twt_ns}/${sample_t}") 
        sample_n=$(printf "%.0f" ${sample_n})
		elev="nan" #this is replaced by a value if a surface pick exists for the current trace
		if [ -a "${surf_hor}.loc" ]; then
			surf_line=$(awk -v trace=${trace} '$7 == trace' ${surf_hor}.loc) #awk reads the line with the required trace number
			if [ -n "${surf_line}" ]; then #sometimes that line doesn't exist, so awk returns nothing
				surf_elev=$(echo ${surf_line} | cut -d ' ' -f 3)
				surf_twt=$(echo ${surf_line} | cut -d ' ' -f 4)
				if [ "${surf_elev}" != "nan" ]; then
				    elev=$(bc <<< "${surf_elev}-${constant}*(${twt_ns}-${surf_twt})")
                    elev=$(printf "%.3f" ${elev})
                fi
			fi
		fi
		echo "${lonlat} ${elev} ${twt_ns} ${twt_lm} ${orbit} ${trace} ${sample_n}" >> "${horizon}.loc"
	done < ${horizon}.tmp
	cat ${horizon}.loc >> ../${horizon}.txt # writes horizon data in final file
done < list.temp

#Everything should be done now, can delete this orbit folder
echo "Done processing ${profile}"
rm -rf ../${profile}
