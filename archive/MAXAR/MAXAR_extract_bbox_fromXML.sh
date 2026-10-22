#!/bin/bash

# Define output CSV file
OUTPUT_FILE="./MAXAR/bounding_boxes.csv"

# Ensure the output file has a header
echo "filename,ULLON,ULLAT,URLON,URLAT,LRLON,LRLAT,LLLON,LLLAT" > "$OUTPUT_FILE"

# Find all XML files (case-insensitive) in nested folders under ./RGB/
find ./MAXAR/RGB/ -type f \( -iname "*.xml" -o -iname "*.XML" \) | while read -r xml; do
    # Extract filename for reference
    filename=$(basename "$xml")

    # Extract relevant lat/lon values using xmllint
    ULLON=$(xmllint --xpath "string(//BAND_B/ULLON)" "$xml" 2>/dev/null)
    ULLAT=$(xmllint --xpath "string(//BAND_B/ULLAT)" "$xml" 2>/dev/null)
    URLON=$(xmllint --xpath "string(//BAND_B/URLON)" "$xml" 2>/dev/null)
    URLAT=$(xmllint --xpath "string(//BAND_B/URLAT)" "$xml" 2>/dev/null)
    LRLON=$(xmllint --xpath "string(//BAND_B/LRLON)" "$xml" 2>/dev/null)
    LRLAT=$(xmllint --xpath "string(//BAND_B/LRLAT)" "$xml" 2>/dev/null)
    LLLON=$(xmllint --xpath "string(//BAND_B/LLLON)" "$xml" 2>/dev/null)
    LLLAT=$(xmllint --xpath "string(//BAND_B/LLLAT)" "$xml" 2>/dev/null)

    # Check if extraction was successful (avoid empty lines)
    if [[ -n "$ULLON" && -n "$ULLAT" && -n "$URLON" && -n "$URLAT" && -n "$LRLON" && -n "$LRLAT" && -n "$LLLON" && -n "$LLLAT" ]]; then
        echo "$filename,$ULLON,$ULLAT,$URLON,$URLAT,$LRLON,$LRLAT,$LLLON,$LLLAT" >> "$OUTPUT_FILE"
    else
        echo "Warning: Missing data in $xml, skipping..."
    fi
done

echo "Extraction complete. Coordinates saved in $OUTPUT_FILE."
