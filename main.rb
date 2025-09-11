# frozen_string_literal: true
require 'octokit'
require 'time'

GITHUB_TOKEN = ENV['GITHUB_TOKEN']
REMINDER_MESSAGE = ENV['REMINDER_MESSAGE']
REVIEW_TURNAROUND_HOURS = ENV['REVIEW_TURNAROUND_HOURS']
PROCESS_REMINDER_MESSAGE = ENV['PROCESS_REMINDER_MESSAGE']
PROCESS_REVIEW_TURNAROUND_HOURS = ENV['PROCESS_REVIEW_TURNAROUND_HOURS']

client = Octokit::Client.new(access_token: GITHUB_TOKEN, per_page: 100)
repo = ENV['GITHUB_REPOSITORY']

begin
  pull_requests = client.pull_requests(repo, state: 'open')

  pull_requests.each do |pr|
    puts "pr #{pr.number}, title: #{pr.title}"

    # Get timeline events and reviews
    timeline = client.get("/repos/#{repo}/issues/#{pr.number}/timeline", per_page: 100)
    review_requested_events = timeline.select { |e| e[:event] == 'review_requested' }
    reviews = client.pull_request_reviews(repo, pr.number)
    comments = client.issue_comments(repo, pr.number)
    current_time = Time.now

    if review_requested_events.empty? || pr.requested_reviewers.empty?
      puts "No pending reviews for PR ##{pr.number}."
    else
      # Check when the last review has been requested
      created_at_value = review_requested_events.last[:created_at]
      pull_request_created_at = created_at_value.is_a?(Time) ? created_at_value : Time.parse(created_at_value)
      review_by_time = pull_request_created_at + (REVIEW_TURNAROUND_HOURS.to_i * 3600)

      puts "currentTime: #{current_time.to_s}"
      puts "reviewByTime: #{review_by_time.to_s}"

      if current_time >= review_by_time
        reviewers = pr.requested_reviewers.map { |rr| "@#{rr[:login]}" }.join(', ')
        add_reminder_comment = "#{reviewers} \n#{REMINDER_MESSAGE}"
        has_reminder_comment = comments.any? { |c| c[:body].include?(REMINDER_MESSAGE) }

        if has_reminder_comment
          puts "Reminder comment already exists for PR ##{pr.number}."
        else
          client.add_comment(repo, pr.number, add_reminder_comment)
          puts "comment created: #{add_reminder_comment}"
        end
      else
        puts "No reminders to send for PR ##{pr.number}."
      end
    end

    # Loop through reviews grouped by [:user][:login] and see if any within a group has the last with state 'CHANGES_REQUESTED'
    # If that is the case, send a message to the PR author with PROCESS_REMINDER_MESSAGE if the review_by_time based on PROCESS_REVIEW_TURNAROUND_HOURS has passed
    reviews_grouped_by_user = reviews.group_by { |r| r[:user][:login] }
    reviews_grouped_by_user.each do |user, user_reviews|
      last_review = user_reviews.max_by { |r| r[:submitted_at] }
      next unless last_review[:state] == 'CHANGES_REQUESTED'

      changes_requested_at_value = last_review[:submitted_at]
      changes_requested_at = changes_requested_at_value.is_a?(Time) ? changes_requested_at_value : Time.parse(changes_requested_at_value)
      process_review_by_time = changes_requested_at + (PROCESS_REVIEW_TURNAROUND_HOURS.to_i * 3600)

      puts "currentTime: #{current_time.to_s}"
      puts "processReviewByTime: #{process_review_by_time.to_s}"

      if current_time >= process_review_by_time
        pr_author = "@#{pr.user[:login]}"
        add_process_reminder_comment = "#{pr_author} \n#{PROCESS_REMINDER_MESSAGE}"
        has_process_reminder_comment = comments.any? { |c| c[:body].include?(PROCESS_REMINDER_MESSAGE) }

        if has_process_reminder_comment
          puts "Process reminder comment already exists for PR ##{pr.number}."
        else
          client.add_comment(repo, pr.number, add_process_reminder_comment)
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
