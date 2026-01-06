# frozen_string_literal: true
require 'octokit'
require 'time'

# Configuration constants
GITHUB_TOKEN = ENV['GITHUB_TOKEN']
REMINDER_MESSAGE = ENV['REMINDER_MESSAGE']
REVIEW_TURNAROUND_HOURS = ENV['REVIEW_TURNAROUND_HOURS'].to_i
PROCESS_REMINDER_MESSAGE = ENV['PROCESS_REMINDER_MESSAGE']
PROCESS_REVIEW_TURNAROUND_HOURS = ENV['PROCESS_REVIEW_TURNAROUND_HOURS'].to_i
GITHUB_REPOSITORY = ENV['GITHUB_REPOSITORY']

API_PER_PAGE = 100
HOURS_IN_DAY = 24
SECONDS_IN_HOUR = 3600

# Validate required environment variables
def validate_environment!
  required_vars = %w[GITHUB_TOKEN REMINDER_MESSAGE REVIEW_TURNAROUND_HOURS PROCESS_REMINDER_MESSAGE PROCESS_REVIEW_TURNAROUND_HOURS GITHUB_REPOSITORY]
  missing_vars = required_vars.select { |var| ENV[var].nil? || ENV[var].empty? }
  
  unless missing_vars.empty?
    puts "Error: Missing required environment variables: #{missing_vars.join(', ')}"
    exit(1)
  end
end

# Helper method to add hours on business days (excluding weekends) to a given time
def add_business_day_hours(start_time, hours)
  return start_time if hours <= 0
  
  time = start_time.dup
  
  hours.times do
    time += SECONDS_IN_HOUR
    # Skip weekends: if we land on Sunday (0), move to Monday
    time += 1 * HOURS_IN_DAY * SECONDS_IN_HOUR if time.utc.wday == 0
    # Skip weekends: if we land on Saturday (6), move to Monday
    time += 2 * HOURS_IN_DAY * SECONDS_IN_HOUR if time.utc.wday == 6
  end
  
  time
end

# Check if a specific comment already exists in the comments list
def comment_exists?(comments, target_comment)
  return false if comments.nil? || target_comment.nil? || target_comment.empty?
  comments.any? { |comment| comment[:body]&.include?(target_comment) }
end

# Create and post a comment to GitHub
def create_comment(client, repo, pr_number, comment_text, comment_type)
  return if comment_text.nil? || comment_text.empty?
  
  client.add_comment(repo, pr_number, comment_text)
  puts "#{comment_type.capitalize} created: #{comment_text}"
rescue => e
  puts "Error creating #{comment_type}: #{e.message}"
end

# Check if reviewer was re-requested for review after their last changes request
def reviewer_re_requested_after_changes?(timeline, reviewer_login, changes_requested_at)
  return false if timeline.nil? || reviewer_login.nil? || changes_requested_at.nil?
  
  timeline.any? do |event|
    event[:event] == 'review_requested' &&
    event[:requested_reviewer] &&
    event[:requested_reviewer][:login] == reviewer_login &&
    event[:created_at] > changes_requested_at
  end
end

validate_environment!
client = Octokit::Client.new(access_token: GITHUB_TOKEN, per_page: API_PER_PAGE)
client.auto_paginate = true

# Send reviewer reminders for overdue reviews
def send_reviewer_reminders(client, repo, pr, timeline, comments, current_time)
  review_requested_events = timeline.select { |e| e[:event] == 'review_requested' }
  requested_reviewers = pr[:requested_reviewers]&.map { |rr| rr[:login] } || []

  if review_requested_events.empty? || requested_reviewers.empty?
    puts "  No pending reviews for PR ##{pr[:number]}."
    return
  end

  # Calculate deadline based on most recent review request (sorted by timestamp)
  last_review_request_time = review_requested_events.max_by { |e| e[:created_at] }[:created_at]
  review_deadline = add_business_day_hours(last_review_request_time, REVIEW_TURNAROUND_HOURS)

  puts "  Review deadline: #{review_deadline} (current: #{current_time})"

  if current_time >= review_deadline
    reviewers_mentions = requested_reviewers.map { |login| "@#{login}" }.join(', ')
    reminder_comment = "#{reviewers_mentions} \n#{REMINDER_MESSAGE}"

    if comment_exists?(comments, reminder_comment)
      puts "  Reviewer reminder already exists for PR ##{pr[:number]}."
    else
      create_comment(client, repo, pr[:number], reminder_comment, "reviewer reminder")
    end
  else
    puts "  No reviewer reminders needed for PR ##{pr[:number]}."
  end
end

# Send process reminders to PR author for addressing change requests
def send_process_reminders(client, repo, pr, timeline, reviews, comments, current_time)
  return if reviews.nil? || reviews.empty?

  reviews.reject { |review| review[:user].nil? }.group_by { |review| review[:user][:login] }.each do |reviewer_login, user_reviews|
    last_review = user_reviews.max_by { |review| review[:submitted_at] }
    next unless last_review[:state] == 'CHANGES_REQUESTED'

    changes_requested_at = last_review[:submitted_at]
    
    # Skip if reviewer has been re-requested for review after requesting changes
    if reviewer_re_requested_after_changes?(timeline, reviewer_login, changes_requested_at)
      puts "  Reviewer #{reviewer_login} re-requested after changes - skipping process reminder for PR ##{pr[:number]}."
      next
    end

    process_deadline = add_business_day_hours(changes_requested_at, PROCESS_REVIEW_TURNAROUND_HOURS)
    puts "  Process deadline for #{reviewer_login}'s feedback: #{process_deadline} (current: #{current_time})"

    if current_time >= process_deadline
      pr_author_mention = "@#{pr[:user][:login]}"
      process_reminder_comment = "#{pr_author_mention} \n#{PROCESS_REMINDER_MESSAGE}"

      if comment_exists?(comments, process_reminder_comment)
        puts "  Process reminder already exists for PR ##{pr[:number]}."
      else
        create_comment(client, repo, pr[:number], process_reminder_comment, "process reminder")
      end
    else
      puts "  No process reminders needed for #{reviewer_login}'s feedback on PR ##{pr[:number]}."
    end
  end
end

# Process a single pull request
def process_pull_request(client, repo, pr, current_time)
  puts "\nProcessing PR ##{pr[:number]}: #{pr[:title]}"

  begin
    # Fetch all required data for this PR
    timeline = client.get("/repos/#{repo}/issues/#{pr[:number]}/timeline", per_page: API_PER_PAGE)
    reviews = client.pull_request_reviews(repo, pr[:number])
    comments = client.issue_comments(repo, pr[:number])

    # Process both types of reminders
    send_reviewer_reminders(client, repo, pr, timeline, comments, current_time)
    send_process_reminders(client, repo, pr, timeline, reviews, comments, current_time)

  rescue => e
    puts "  Error processing PR ##{pr[:number]}: #{e.message}"
  end
end

begin
  puts "Starting GitHub review reminder app for repository: #{GITHUB_REPOSITORY}"
  puts "Review turnaround: #{REVIEW_TURNAROUND_HOURS} hours"
  puts "Process turnaround: #{PROCESS_REVIEW_TURNAROUND_HOURS} hours"
  puts "=" * 50

  pull_requests = client.pull_requests(GITHUB_REPOSITORY, state: 'open')
  current_time = Time.now.utc
  
  if pull_requests.empty?
    puts "No open pull requests found."
  else
    puts "Found #{pull_requests.length} open pull request(s)."
    
    pull_requests.each do |pr|
      process_pull_request(client, GITHUB_REPOSITORY, pr, current_time)
    end
  end

  
  puts "\n" + "=" * 50
  puts "GitHub review reminder app completed successfully."
rescue Octokit::Unauthorized
  puts "Error: GitHub authentication failed. Please check your GITHUB_TOKEN."
  exit(1)
rescue Octokit::NotFound
  puts "Error: Repository '#{GITHUB_REPOSITORY}' not found or not accessible."
  exit(1)
rescue Octokit::TooManyRequests
  puts "Error: GitHub API rate limit exceeded. Please try again later."
  exit(1)
rescue StandardError => e
  puts "Unexpected error: #{e.message}"
  exit(1)
end
