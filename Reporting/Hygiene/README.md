# Hygiene Report
A Hygiene Report has been created that can help PMO officers and Administrators identify Projects/Programs/Portfolios, Resources, and Register items that need to be cleaned up or Projects that are nearing their forecast finish.

 - [<img src="../images/TemplateFile-48.png" width="16px">Hygiene Report.pbit](files/Hygiene Report.pbit)  

This report has been built using the dimension tables from the shared data model with additional values and calculations added to it using SQL direct queries. These queries can be added to if clients would like additional items added to this report.

This report contains the following tabs and calculations:
- Resource Hygiene
  - Active Resources that have an End Date in the past
  - Resources without a Primary Role
  - Resources without an Enterprise Calendar
  - Resources without a Line Manager
  - Resources without a Timesheet Manager
  - Resources without a Cost Rate
  - Resources without a Sell Rate
- Project Hygiene
  - Active Projects with a Scheduled Finish date in the past
  - Active Projects with a Target Finish date in the past
  - Projects that have an EAC value higher than their Budget value
  - Projects with 10% or less remaining
  - Projects with 80 hours or less remaining
- Inactive User - Projects and Tasks
  - Future Tasks allocated to an Inactive Resource
  - Future Resource Requests for Inactive Resources
- Inactive User - Active Register
  - A list of all Active registers records that are Assigned to Inactive Resources 
- Inactive Project - Active Registers
  - A list of all Active register records that are within Inactive Projects, Programs or Portfolios
