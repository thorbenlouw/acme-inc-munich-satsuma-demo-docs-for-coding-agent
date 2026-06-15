# Step 1 — Show that the agent understands Satsuma

> What do you know about reading and writing Satsuma?

Also show the output from the analysis.

---
Attempt most of these with a cheap, quick model like Haiku. For complex tasks (like reverse engineering the spec from XLSX), use Opus

* After reading the Satsuma spec, can you generate some sample appropriate data examples for the input schemas in `sample-data/`?

* In `@implementation/` create a Gherkin spec of some edge cases to test for in the kunden-to-SF mapping pipelines.

* Suggest a top-10 manual e2e test case plan in `@implementation/test-plan.md`, prioritising compliance risk and complex logic.

* In a subfolder in `@implementation/`, generate an Azure Data Factory Mapping DataFlow implementation for the billing_api to assets pipeline.

* In a subfolder in `implementation/`, create a Databricks Lakehouse Declarative Pipeline implementation (notebook) for the kunden → Salesforce export data product pipeline. Follow ACME Conventions. [Use a good model here like Opus]

* What are the top GDPR-related risks to focus on in this pipeline? Which target fields contain PII and what is their source?

* Tell me about unanswered questions in the spec.

* Generate a Satsuma spec from the Excel file in `@analysis-output/Customer_Migration_Mapping_v17_FINAL_(2).xlsx`.

* What's missing in `first_attempt`?
