class Video
  module HTTPParamConverter
    def self.from_rs(rs)
      HTTP::Params.parse(rs.read(String))
    end
  end

  def initialize(id, info, updated, title, views, likes, dislikes, wilson_score, published, description)
    @id = id
    @info = info
    @updated = updated
    @title = title
    @views = views
    @likes = likes
    @dislikes = dislikes
    @wilson_score = wilson_score
    @published = published
    @description = description
  end

  def to_a
    return [@id, @info, @updated, @title, @views, @likes, @dislikes, @wilson_score, @published, @description]
  end

  DB.mapping({
    id:   String,
    info: {
      type:      HTTP::Params,
      default:   HTTP::Params.parse(""),
      converter: Video::HTTPParamConverter,
    },
    updated:      Time,
    title:        String,
    views:        Int64,
    likes:        Int32,
    dislikes:     Int32,
    wilson_score: Float64,
    published:    Time,
    description:  String,
  })
end

class RedditSubmit
  JSON.mapping({
    data: RedditSubmitData,
  })
end

class RedditSubmitData
  JSON.mapping({
    children: Array(RedditThread),
  })
end

class RedditThread
  JSON.mapping({
    data: RedditThreadData,
  })
end

class RedditThreadData
  JSON.mapping({
    subreddit:    String,
    id:           String,
    num_comments: Int32,
    score:        Int32,
    author:       String,
    permalink:    String,
    title:        String,
  })
end

# See http://www.evanmiller.org/how-not-to-sort-by-average-rating.html
def ci_lower_bound(pos, n)
  if n == 0
    return 0.0
  end

  # z value here represents a confidence level of 0.95
  z = 1.96
  phat = 1.0*pos/n

  return (phat + z*z/(2*n) - z * Math.sqrt((phat*(1 - phat) + z*z/(4*n))/n))/(1 + z*z/n)
end

def elapsed_text(elapsed)
  millis = elapsed.total_milliseconds
  return "#{millis.round(2)}ms" if millis >= 1

  "#{(millis * 1000).round(2)}µs"
end

def get_client(pool)
  while pool.empty?
    sleep rand(0..10).milliseconds
  end

  return pool.shift
end

def fetch_video(id, client)
  info = client.get("/get_video_info?video_id=#{id}&el=detailpage&ps=default&eurl=&gl=US&hl=en").body
  html = client.get("/watch?v=#{id}").body

  html = XML.parse_html(html)
  info = HTTP::Params.parse(info)

  if info["reason"]?
    info = client.get("/get_video_info?video_id=#{id}&ps=default&eurl=&gl=US&hl=en").body
    info = HTTP::Params.parse(info)
    if info["reason"]?
      raise info["reason"]
    end
  end

  title = info["title"]

  views = info["view_count"].to_i64

  likes = html.xpath_node(%q(//button[@title="I like this"]/span))
  likes = likes ? likes.content.delete(",").to_i : 0

  dislikes = html.xpath_node(%q(//button[@title="I dislike this"]/span))
  dislikes = dislikes ? dislikes.content.delete(",").to_i : 0

  description = html.xpath_node(%q(//p[@id="eow-description"]))
  description = description ? description.to_xml : ""

  wilson_score = ci_lower_bound(likes, likes + dislikes)

  published = html.xpath_node(%q(//strong[contains(@class,"watch-time-text")]))
  if published
    published = published.content
  else
    raise "Could not find date published"
  end

  published = published.lchop("Published ")
  published = published.lchop("Streamed live ")
  published = published.lchop("Started streaming ")
  published = published.lchop("on ")
  published = published.lchop("Scheduled for ")
  if !published.includes?("ago")
    published = Time.parse(published, "%b %-d, %Y")
  else
    # Time matches format "20 hours ago", "40 minutes ago"...
    delta = published.split(" ")[0].to_i
    case published
    when .includes? "minute"
      published = Time.now - delta.minutes
    when .includes? "hour"
      published = Time.now - delta.hours
    else
      raise "Could not parse #{published}"
    end
  end

  video = Video.new(id, info, Time.now, title, views, likes, dislikes, wilson_score, published, description)

  return video
end

def get_video(id, client, db, refresh = true)
  if db.query_one?("SELECT EXISTS (SELECT true FROM videos WHERE id = $1)", id, as: Bool)
    video = db.query_one("SELECT * FROM videos WHERE id = $1", id, as: Video)

    # If record was last updated over an hour ago, refresh (expire param in response lasts for 6 hours)
    if refresh && Time.now - video.updated > 1.hours
      video = fetch_video(id, client)
      db.exec("DELETE FROM videos * WHERE id = $1", id)
      args = arg_array(video.to_a)
      db.exec("INSERT INTO videos VALUES (#{args})", video.to_a)
    end
  else
    video = fetch_video(id, client)
    args = arg_array(video.to_a)
    db.exec("INSERT INTO videos VALUES (#{args})", video.to_a)
  end

  return video
end

def search(query, client)
  html = client.get("https://www.youtube.com/results?q=#{query}&sp=EgIQAVAU").body

  html = XML.parse_html(html)

  html.xpath_nodes(%q(//ol[@class="item-section"]/li)).each do |item|
    root = item.xpath_node(%q(div[contains(@class,"yt-lockup-video")]/div))
    if root
      link = root.xpath_node(%q(div[contains(@class,"yt-lockup-thumbnail")]/a/@href))
      if link
        yield link.content.split("=")[1]
      end
    end
  end
end

def splice(a, b)
  c = a[0]
  a[0] = a[b % a.size]
  a[b % a.size] = c
  return a
end

def decrypt_signature(a)
  a = a.split("")

  a.reverse!
  a.delete_at(0..2)
  a = splice(a, 35)
  a.delete_at(0)
  a.reverse!
  a = splice(a, 54)

  return a.join("")
end

def rank_videos(db, n)
  top = [] of {Float64, String}

  db.query("SELECT id, wilson_score, published FROM videos WHERE views > 5000 ORDER BY published DESC LIMIT 10000") do |rs|
    rs.each do
      id = rs.read(String)
      wilson_score = rs.read(Float64)
      published = rs.read(Time)

      # Exponential decay, older videos tend to rank lower
      temperature = wilson_score * Math.exp(-0.000005*((Time.now - published).total_minutes))
      top << {temperature, id}
    end
  end

  top.sort!

  # Make hottest come first
  top.reverse!
  top = top.map { |a, b| b }

  # Return top
  return top[0..n - 1]
end

def make_client(url, context)
  client = HTTP::Client.new(url, context)
  client.read_timeout = 30.seconds
  client.connect_timeout = 30.seconds
  return client
end

def get_reddit_comments(id, client)
  youtube_url = "https://www.youtube.com/watch?v=#{id}"
  search_results = client.get("/submit.json?url=#{youtube_url}")

  if search_results.status_code == 302
    search_results = client.get(search_results.headers["Location"]).body

    result = JSON.parse(search_results)

    thread = RedditThread.from_json(result[0]["data"]["children"][0].to_json)
  else
    search_results = RedditSubmit.from_json(search_results.body)

    thread = search_results.data.children.sort_by { |child| child.data.score }[-1]

    result = client.get("/r/#{thread.data.subreddit}/comments/#{thread.data.id}?sort=top&depth=3").body
    result = JSON.parse(result)
  end
  comments = result[1]["data"]["children"]

  return comments, thread
end

def template_comments(root)
  html = ""
  root.each do |child|
    if child["data"]["body_html"]?
      author = child["data"]["author"]
      score = child["data"]["score"]
      body_html = HTML.unescape(child["data"]["body_html"].as_s)

      replies_html = ""
      if child["data"]["replies"] != ""
        replies_html = template_comments(child["data"]["replies"]["data"]["children"])
      end

      content = <<-END_HTML
      <p>
        <a class="link" href="javascript:void(0)" onclick="toggle(this)">[ - ]</a> #{score} <b>#{author}</b> 
      </p>
      <div>
      #{body_html}
      #{replies_html}
      </div>
      END_HTML

      if child["data"]["depth"].as_i > 0
        html += <<-END_HTML
          <div class="pure-g">
          <div class="pure-u-1-24"></div>
          <div class="pure-u-23-24">
          #{content}
          </div>
          </div>
        END_HTML
      else
        html += <<-END_HTML
          <div class="pure-g">
          <div class="pure-u-1">
          #{content}
          </div>
          </div>
        END_HTML
      end
    end
  end

  return html
end

def number_with_separator(number)
  number.to_s.reverse.gsub(/(\d{3})(?=\d)/, "\\1,").reverse
end

def arg_array(array)
  args = [] of String
  (1..array.size).each { |i| args << "($#{i})," }
  args = args.join("")
  args = args.chomp(",")

  return args
end
