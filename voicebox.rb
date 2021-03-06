#!/usr/bin/env ruby

# Copyright (C) 2012 brjannc <brjannc at gmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

require 'cgi'
require 'date'
require 'haml'
require 'iconv'
require 'sinatra'
require 'sinatra/reloader' if development?
require 'yaml'

configure do
  # TODO: set up default config with some sample logs

  set :static_cache_control, [:public, :max_age => 604800] unless development?
  set :threaded, true

  if File.readable?('config.yml')
    config = YAML::load_file('config.yml')

    # precompile all the format pattern regexes
    config['formats'].each do |format, patterns|
      patterns.update(patterns) { |k, v| Regexp.new(v) }
    end

    set :channels, config['channels']
    set :formats, config['formats']
    set :version, "0.1"
  end
  
  set :ic, Iconv.new('UTF-8//IGNORE', 'UTF-8')
end

# match /<channel>/<year>/<month>/<day>/[?format=html|txt]
get %r{^/(\w+)/(\d{4})/(\d{2})/(\d{2})/?$} do |channel, year, month, day|
  pass unless settings.channels.include?(channel)

  config = settings.channels[channel]
 
  @channel_name = config['channel-name']
  @log_format = config['log-format']

  begin
    date = Date.new(year.to_i, month.to_i, day.to_i)
  rescue
    pass
  end

  #format = params[:format].nil? ? 'html' : params[:format]
  format = 'html'

  @log = channel_log(channel, date)
  pass unless File.readable?(@log)

  case format
  when /html?/
    haml :date
  when /txt/
    send_file @log, :type => :text
  else
    pass
  end
end

get %r{^/(\w+)/(\d{4})/(\d{2})/?$} do |channel, year, month|
  pass unless settings.channels.include?(channel)

  @year = year.to_i
  @month = month.to_i

  @channel = channel
  @channel_name = settings.channels[channel]['channel-name']
  @dates = Set.new(channel_dates(channel, @year, @month))

  @date = Date.new(@year, @month, 1)
  @date -= @date.wday

  haml :month
end

get %r{^/(\w+)/?$} do |channel|
  pass unless settings.channels.include?(channel)

  redirect Date.today.strftime("/#{channel}/%Y/%m/")

  # @channel = channel
  # @channel_name = settings.channels[channel]['channel-name']
  # @dates = channel_dates(channel)

  # pass if @dates.empty?

  # @dates.sort!.reverse!

  # haml :channel
end

# match /
get %r{^/$} do
  haml :index
end

helpers do
  def days_in_month(year, month)
    (Date.new(year, 12, 31) << (12 - month)).day
  end

  def channel_log_uri(channel, date)
    date.strftime("/#{channel}/%Y/%m/%d/")
  end

  def channel_log(channel, date)
    # TODO: error checking

    config = settings.channels[channel]
    date.strftime("#{config['log-directory']}/#{config['log-template']}")
  end

  def channel_dates(channel, year = nil, month = nil)
    # TODO: error checking
    config = settings.channels[channel]
    template = "#{config['log-directory']}/#{config['log-template']}"

    if year and month
      pattern = template.gsub(/%Y/, year.to_s).gsub(/%m/, sprintf("%02d", month)).gsub(/(%[^%])+/, '*')
    else
      pattern = template.gsub(/(%[^%])+/, '*')
    end
    
    Dir.glob(pattern).map { |filename| DateTime.strptime(filename, template) }
  end

  def link_to(url, text = url, opts = {})
    attributes = ''
    opts.each { |key,value| attributes << key.to_s << '="' << value << '" '}
    "<a href=\"#{url}\" #{attributes}>#{text}</a>"
  end

  def linkify(text)
    CGI.escapeHTML(text).gsub %r{((https?://|www\.)([-\w\.]+)+(:\d+)?(/([-\w/_\.]*(\?\S+)?)?)?)}, %Q{<a href="\\1">\\1</a>}
  end

  def sanitize(text)
    settings.ic.iconv(text + ' ')[0..-2]
  end

  def markup(line, format)
    line.chomp!

    tokens = line.partition(" ")
    timestamp = tokens[0]
    text = linkify(sanitize(tokens[2]))
    text_class = nil

    settings.formats[format].each do |type, pattern|
      if match = pattern.match(text)
        text_class = type

        # if this line is a message or action, colorize the nick
        if type == "message" || type == "action"
          nick = match[1]
          color = nick.sum(3) + 1
          text.sub!(nick, %Q{<span class="c#{color}">#{nick}</span>})
        end

        # if we found a match, we can break out early; the patterns should be mutually exclusive
        break
      end
    end

    # debugging
    if text_class.nil?
      print "Unmatched text! #{line}\n"
      text_class = "message"
    end

    <<-eos
<span class="timestamp">#{timestamp}</span>
<span class="#{text_class}">#{text}</span>
    eos
  end
end
