FROM ruby:3.4

WORKDIR /app
COPY main.rb /app/main.rb
RUN gem install octokit

ENTRYPOINT ["ruby", "/app/main.rb"]
