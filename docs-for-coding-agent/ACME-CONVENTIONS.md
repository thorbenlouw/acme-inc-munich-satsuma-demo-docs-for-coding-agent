* All personal data fields MUST have the meta tag 'pii'
* Schemas containing PII should have meta stating 'retention'
* All schemas must have a note meta describing the data


## Lakehouse declarative pipelines
* Prefer SQL Syntax
* our Unity Catalog contains catalogs for {env}_{layer} like prod_bronze, or dev_gold. Within that there are schemas for each data product. 
* Source data products in bronze and silver should have source-aligned names using a-z_ . 
* Gold data products must have a business-concept aligned naming. They MUST be dimensional data products. 
* Data products for reverse ETL (export) live in Gold and are Wide Tables
* Add description/metadata for all table columns to describe fully
* Use tags `pii:true` on PII cols
* Every table must have a good metadata description including the owner. 