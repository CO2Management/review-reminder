# frozen_string_literal: true
require 'octokit'
require 'time'

# Helper method to add hours on business days (excluding weekends) to a given time
def add_business_day_hours(start_time, hours)
  time = start_time.dup
  
  hours.times do
    time += 3600  # Add one hour
    # Skip weekends
    time += 1 * 24 * 3600 if time.wday == 0  # Skip Sunday -> Monday
    time += 2 * 24 * 3600 if time.wday == 6  # Skip Saturday -> Sunday -> Monday
  end
  
  time
end

GITHUB_TOKEN = ENV['GITHUB_TOKEN']
REMINDER_MESSAGE = ENV['REMINDER_MESSAGE']
REVIEW_TURNAROUND_HOURS = ENV['REVIEW_TURNAROUND_HOURS']
PROCESS_REMINDER_MESSAGE = ENV['PROCESS_REMINDER_MESSAGE']
PROCESS_REVIEW_TURNAROUND_HOURS = ENV['PROCESS_REVIEW_TURNAROUND_HOURS']
REPO = ENV['GITHUB_REPOSITORY']

client = Octokit::Client.new(access_token: GITHUB_TOKEN, per_page: 100)

begin
  pull_requests = client.pull_requests(REPO, state: 'open')

  pull_requests.each do |pr|
    puts "pr #{pr.number}, title: #{pr.title}"

    # Get timeline events and reviews
    timeline = client.get("/repos/#{REPO}/issues/#{pr.number}/timeline", per_page: 100)
    review_requested_events = timeline.select { |e| e[:event] == 'review_requested' }
    reviews = client.pull_request_reviews(REPO, pr.number)
    comments = client.issue_comments(REPO, pr.number)
    current_time = Time.now
    requested_reviewers = pr.requested_reviewers.map { |rr| rr[:login] }

    if review_requested_events.empty? || requested_reviewers.empty?
      puts "No pending reviews for PR ##{pr.number}."
    else
      # Check when the last review has been requested
      created_at_value = review_requested_events.last[:created_at]
      pull_request_created_at = created_at_value.is_a?(Time) ? created_at_value : Time.parse(created_at_value)
      review_by_time = add_business_day_hours(pull_request_created_at, REVIEW_TURNAROUND_HOURS.to_i)

      puts "currentTime: #{current_time.to_s}"
      puts "reviewByTime: #{review_by_time.to_s}"

      if current_time >= review_by_time
        reviewers = requested_reviewers.map { |rr| "@#{rr}" }.join(', ')
        add_reminder_comment = "#{reviewers} \n#{REMINDER_MESSAGE}"

        if comments.any? { |c| c[:body].include?(REMINDER_MESSAGE) }
          puts "Reminder comment already exists for PR ##{pr.number}."
        else
          client.add_comment(REPO, pr.number, add_reminder_comment)
          puts "comment created: #{add_reminder_comment}"
        end
      else
        puts "No reminders to send for PR ##{pr.number}."
      end
    end

    # Loop through reviews grouped by [:user][:login] and see if any within a group has the last with state 'CHANGES_REQUESTED'
    # If that is the case, send a message to the PR author with PROCESS_REMINDER_MESSAGE if the review_by_time based on PROCESS_REVIEW_TURNAROUND_HOURS has passed
    reviews.group_by { |r| r[:user][:login] }.each do |user, user_reviews|
      last_review = user_reviews.max_by { |r| r[:submitted_at] }
      next unless last_review[:state] == 'CHANGES_REQUESTED'

      changes_requested_at_value = last_review[:submitted_at]
      changes_requested_at = changes_requested_at_value.is_a?(Time) ? changes_requested_at_value : Time.parse(changes_requested_at_value)
      process_review_by_time = add_business_day_hours(changes_requested_at, PROCESS_REVIEW_TURNAROUND_HOURS.to_i)

      puts "currentTime: #{current_time.to_s}"
      puts "processReviewByTime: #{process_review_by_time.to_s}"

      if current_time >= process_review_by_time
        pr_author = "@#{pr.user[:login]}"
        add_process_reminder_comment = "#{pr_author} \n#{PROCESS_REMINDER_MESSAGE}"

        if comments.any? { |c| c[:body].include?(PROCESS_REMINDER_MESSAGE) }
          puts "Process reminder comment already exists for PR ##{pr.number}."
        else
          client.add_comment(REPO, pr.number, add_process_reminder_comment)
          puts "Process reminder comment created: #{add_process_reminder_comment}"
        end
      else
        puts "No process reminders to send for PR ##{pr.number}."
      end
    end
  end
rescue StandardError => e
  puts "Failed: #{e.message}"
  exit(1)
end
