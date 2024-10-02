# Paginated Reports Solution Starters

Paginated reports have been created to compliment Altus installation to generate status reports for projects, program and portfolio.
These reports use only .rdl file which can be developed using Power BI Report Builder. It has direct SQL connection to Dataverse which contains Altus information. This is then published to Power BI Service as .rdl file.

## Reports

### Project Status Reports

Project status report contains following information

-  Project info and Project status like General KPI, Deliverables KPI, Schedule KPI, Financials KPI, Work KPI, Issues KPI, Risks KPI, Change Requests KPI and Project Progress and Effort pie chart
- Financials - EAC by Financial Category line chart and Cost by Month bar chart, Category Costs and Financials
- Milestones and Key Dates
- Deliverables
- Issues
- Risks
- Decisions
- Change Requests
- Lessons Learned


 rdl file can be downloaded from - [Download .rdl file for Project Status Report](./files/Project_Status_Report/Reports/Altus_Project_Status_Report.zip)

#### Datasets 
There are 14 datasets for Project status report which are direct SQL queries
    
    dsProject
    dsTasks
    dsKeyDates
    dsDeliverables
    dsIssues
    dsRisks
    dsDecisions
    dsChanges
    dsChanges
    dsChanges
    dsLessons
    lookup_Project
    dsMilestones
    dsFinancialTransactions
    dsStatusUpdate
    dsTransactionCurrency


SQL Files which are used for datasets can be downloaded from - [Download SQL Code for Project Status Report](./files/Project_Status_Report/SQL/Project_Status_Report_Dataset_SQL_Code.zip)


#### Parameters 
- __Project Id__ - parameter that will be passed for most of the datasets. This will be hidden in the reports and when embedded in Altus it fetches the project that is currently open in Altus and passes the id as paramater


### Program Status Reports
Program status report contains following information

- Program Info and Program Status like General KPI, Deliverables KPI, Schedule KPI, Financials KPI, Work KPI, Issues KPI, Risks KPI, Change Requests KPI and Program Progress and Project Effort pie chart
- Associated Project Financials - EAC by Financial Category line chart and Cost by Month bar chart, Category Costs and Financials
- Program Key Dates
- Program Issues
- Program Risks
- Program Decisions
- Program Change Requests
- Program Lessons Learned
- Associated Project Summary

rdl file can be downloaded from - [Download .rdl file for Program Status Report](./files/Program_Status_report/Reports/Altus_Program_Status_Report.zip)

#### Datasets   
There are 18 datasets for Project status report which are direct SQL queries

    dsProject
    dsKeyDates
    dsIssues
    dsRisks
    dsDecisions
    dsChanges
    dsLessons
    lookup_project
    dsFinancialTransactions
    dsStatusUpdate
    lookup_Program
    dsProgram
    dsStatusUpdate_Project
    dsIssues_Project
    dsRisks_Project
    dsDecisions_Project
    dsChangeRequest_Project
    dsTransactionCurrency

SQL Files which are used for datasets can be downloaded from - [Download SQL Code for Program Status Report](./files/Program_Status_report/SQL/Program_Status_Report_Dataset_SQL_Code.zip)

#### Parameters 

- __Program Id__ - parameter that will be passed for most of the datasets. This will be hidden in the reports and when embedded in Altus it fetches the program that is currently open in Altus and passes the id as parameter


### Portfolio Status Reports

Program status report contains following information

- Portfolio Info and Portfolio Summary like Description, Justification, Stakeholder Communications and Vision
- Portfolio Key Dates
- Portfolio Risks
- Portfolio Decisions
- Portfolio Change Requests
- Summary - Associated Projects and Programs linked to projects
- Associated Project and Program Issues
- Associated Project and Program Risks
- Associated Project and Program Decisions
- Associated Project and Program Change Requests

rdl file can be downloaded from - [Download .rdl file for Portfolio Status Report](./files/Portfolio_Status_Report/Reports/Altus_Portfolio_Status_Report.zip)

#### Datasets 

There are 16 datasets for Project status report which are direct SQL queries

    dsProject
    dsKeyDates
    dsRisks
    dsDecisions
    dsChanges
    lookup_Project
    dsFinancialTransactions_Portfolio_Project
    lookup_Portfolio
    dsPortfolio
    dsStatusUpdate_Project
    dsIssues_Project_Program
    dsRisks_Project_Program
    dsDecisions_Project_Program
    dsChangeRequest_Project_Program
    dsStatusUpdate_Program
    dsTransactionCurrency

SQL Files which are used for datasets can be downloaded from - [Download SQL Code for Portfolio Status Report](./files/Portfolio_Status_Report/SQL/Portfolio_Status_Report_Dataset_SQL_Code.zip)

#### Parameters 

- __Portfolio Id__ - parameter that will be passed for most of the datasets. This will be hidden in the reports and when embedded in Altus it fetches the portfolio that is currently open in Altus and passes the id as parameter

## Embedding inside Altus

## Installing the Reports in a Client's environment

### PowerBI Updates

#### Project Status Report
1. Open the .rdl file which you have downloaded from the above steps and navigae to parameters like shown below:

[Parameter Updates](./images/ProjectImage1.png){.contentImage65}

### Publishing it to PowerBI Service

