# Preprocessing of transcripts

### Metadata cleaning
```bash
python clean-metadata.py --input-dir pdf-to-txt/precleaned-txt --output-dir pdf-to-txt/postcleaned-txt --join-line --normalize-spaces --dehyphenate 
```

### Difference comparison

enter the names of the file you want to compare after the --names
```bash
python comp-docs.py "pdf-to-txt/precleaned-txt" "pdf-to-txt/postcleaned-txt" -o "/Users/xiyuancao/Desktop/topic-extraction/pdf-to-txt/docs-diffs" --names RG-50.106.0218_trs_en.txt RG-50.042.0018_trs_en.txt RG-50.233.0077_trs_en.txt RG-50.030.0148_trs_en.txt RG-50.471.0007_trs_en.txt RG-50.999.0574_trs_en.txt RG-50.233.0126_trs_en.txt RG-50.549.02.0071_trs_en.txt RG-50.344.0005_trs_en.txt
```

Then navigate to pdf-to-txt/docs-diffs and use go live in VSCode to view it in a browser. 