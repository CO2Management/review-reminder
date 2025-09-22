# Review reminder script for GitHub Actions

## Summary
Send GitHub mentions after given time periods
- when a PR is pending for review for a certain time
- when the assignee hasn't processed the feedback after a certain time

## Setup
Create a file with the following content under `.github/workflows/review-reminder.yml`.

```yml
name: 'Review reminder'
on:
  schedule:
    # Check reviews every weekday at 7:00
    - cron: '0 7 * * 1-5'
    
jobs:
  review-reminder: 
    runs-on: ubuntu-latest
    steps:
      - uses: CO2Management/review-reminder@main
        with:
          github_repository: 'CO2Management/co2m' # Required. Repository where the action is based.
          github_token: ${{ secrets.GITHUB_TOKEN }} # Required
          reminder_message: 'Three business days have passed since the review started. Give priority to reviews as much as possible.' # Required. Messages to send to reviewers on Github.
          review_turnaround_hours: 72 # Required. This is the deadline for reviews. If this time is exceeded, a reminder wil be send.
          process_reminder_message: 'A week has passed since changes were requested. Please give priority to processing the feedback.' # Required
          process_review_turnaround_hours: 168 # Required
```
