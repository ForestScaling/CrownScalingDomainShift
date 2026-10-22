#!/bin/bash

# Base directory
base_dir="/fs/ess/PUOM0017/ForestScaling/DeepForest/Imagery/NEON/DP3.30010.001/neon-aop-products/"

# Year to process
YEAR=2022

# Loop over all domains (D01 to D20)
for DOMAIN in D{01..20}; do

    year_dir="${base_dir}${YEAR}/FullSite/"
    domain_dir="${year_dir}/${DOMAIN}/"

    # Check if the domain directory exists
    if [ ! -d "$domain_dir" ]; then
        echo "Domain directory $domain_dir does not exist, skipping..."
        continue
    fi

    # Get list of sites (folders) in the domain directory
    sites_list=$(ls -d "${domain_dir}"*/ 2>/dev/null | xargs -n 1 basename)
    sites_list="2022_BART_6"

    # Loop over each site in the domain
    for site in $sites_list; do

        # Define input and output directories
        input_dir="${domain_dir}/${site}/L3/Camera/Mosaic/"
        output_dir="${domain_dir}/${site}/L3/Resample/cm30/"

        # Check if the input directory exists
        if [ ! -d "$input_dir" ]; then
            echo "Input directory $input_dir does not exist for site $site, skipping..."
            continue
        fi

        # Create the output directory if it doesn't exist
        mkdir -p "$output_dir"

        # Loop over all TIFF files in the input directory
        for img in "$input_dir"/*.tif; do
            # Check if there are TIFF files to process
            if [ ! -f "$img" ]; then
                echo "No TIFF files found in $input_dir, skipping..."
                continue
            fi

            # Extract filename without path
            filename=$(basename "$img")

            # Define output file
            output_img="$output_dir/${filename%.tif}_30cm.tif"

            utm_zone=$(gdalinfo "$img" | grep -oE '"EPSG","326[0-9]+"'| grep -oE '326[0-9]+')

            # Resample the image to 30cm resolution using cubic interpolation
            gdalwarp -tr 0.3 -0.3 -r cubic -t_srs "EPSG:$utm_zone" "$img" "$output_img"

            echo "Resampled $img -> $output_img"
        done
    done
done

