## Step 0 - The project landscape
Show the "analysis-output" style docs that we can
expect to have from AI+human analysis: [analysis-output/](analysis-output)

* Markdown architecture overview
* All natural language text
* What we know about the source and target

This also led to the BA (Sabine's) current-day version of a data-mapping spec that's NOT AI 
friendly -- [analysis-output/Customer_Migration_Mapping_v17_FINAL_(2).xlsx](analysis-output/Customer_Migration_Mapping_v17_FINAL_(2).xlsx)

## Step 1 — Show that the agent setup understands Satsuma

> What do you know about reading and writing Satsuma?

Copy the [acme_vorbild.stm](../pregenerated_for_demo/specs/acme_vorbild.stm) to spec to show, then Step 2 completes


## Step 2 - begin inferring a satsuma spec (takes about X min)

Use Opus!

> Generate a Satsuma spec from the Excel file in `@analysis-output/Customer_Migration_Mapping_v17_FINAL_(2).xlsx`.


In the meantime, we'll talk about Satsuma



> 

## Step 3 - 

Attempt most of these with a cheap, quick model like Haiku.

* Show a simple schema from [first attempt by Sabine](../pregenerated_for_demo/specs/first_attempt.stm) 

* Show a meta-decorated schema from [acme_vorbild.stm](../../pregenerated_for_demo/specs/acme_vorbild.stm) 

* Show a simple mapping 

* Show the code and the human viz

> Tell me about unanswered questions in the spec.


> After reading the Satsuma spec, can you generate some sample appropriate data examples for the input schemas in `sample-data/`?


> Suggest a top-10 manual e2e test case plan in `@implementation/test-plan.md`, prioritising compliance risk and complex logic.


> What are the top GDPR-related risks to focus on in this pipeline? Which target fields contain PII and what is their source?

## Step 4

Generating implementations (if time)

> In `@implementation/` create a Gherkin spec of some edge cases to test for in the kunden-to-SF mapping pipelines.

> In a subfolder in `@implementation/`, generate an Azure Data Factory Mapping DataFlow implementation for the billing_api to assets pipeline.

* In a subfolder in `implementation/`, create a Databricks Lakehouse Declarative Pipeline implementation (notebook) for the kunden → Salesforce export data product pipeline. Follow ACME Conventions. [Use a good model here like Opus]

