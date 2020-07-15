require "sinatra"
require "trello"
require "omniauth"
require "omniauth-trello"
require "trello"
require "open3"
require "erb"
require "securerandom"

set :port, ENV.fetch("PORT", "4567")
set :session_secret, ENV.fetch("SESSION_SECRET", SecureRandom.hex(64))
enable :sessions

use OmniAuth::Builder do
  provider(
    :trello,
    ENV.fetch("TRELLO_KEY"),
    ENV.fetch("TRELLO_TOKEN"),
    app_name: "trello-zettelkasten",
    scope: "read,account",
    expiration: "1day",
  )
end


get "/" do
  if session.has_key?(:token)
    client = Trello::Client.new(
      consumer_key: ENV.fetch("TRELLO_KEY"),
      consumer_secret: ENV.fetch("TRELLO_TOKEN"),
      oauth_token: session.fetch(:token),
    )

    person = client.find(:members, "me")

    erb :main, locals: {
      signed_in: true,
      person: person,
      boards: person.boards,
    }
  else
    erb :main, locals: {
      signed_in: false,
    }
  end
end

get "/visualise" do
  redirect to("/auth/trello") unless session.has_key?(:token)

  client = Trello::Client.new(
    consumer_key: ENV.fetch("TRELLO_KEY"),
    consumer_secret: ENV.fetch("TRELLO_TOKEN"),
    oauth_token: session.fetch(:token),
  )

  board_ids = params.keys

  boards = board_ids.map do |board_id|
    client.find(:boards, board_id)
  end

  cards = boards.flat_map do |board|
    board.cards
  end

  erb :visualise, locals: {
    board_names: boards.map {|b| b.name}.join(","),
    graph: draw_graph(cards)
  }
end

get "/auth/trello/callback" do
  session[:token]  = request.env.dig(
    "omniauth.auth",
    "credentials",
    "token"
  )
  redirect to("/")
end

CARD_PATTERN = /https:\/\/trello[.]com\/c\/[A-Za-z0-9]+/

GraphNode = Struct.new(:id, :label, :href, :desc, :tags)
GraphEdge = Struct.new(:from, :to)

def get_card_url_prefix(url)
  url.match(CARD_PATTERN)[0]
end

def draw_graph(cards)
  graph_nodes = cards.map do |card|
    GraphNode.new(
      get_card_url_prefix(card.url),
      card.name,
      card.url,
      card.desc,
      card.labels.map{ |l| l.name },
    )
  end

  graph_edges = graph_nodes.flat_map do |node|
    node.desc.scan(CARD_PATTERN).map do |match|
      GraphEdge.new(node.id, match)
    end
  end

  template = <<~'ERB'
  digraph g {

    <% graph_nodes.each do |node| %>
    "<%= node.id %>" [
      label = <
        <table border="0" cellborder="1" cellspacing="0" cellpadding="4">
          <tr><td href="<%= node.href %>"><font color="#1d70b8"><u><%= node.label %></u></font></td></tr>
          <% node.tags.each do |tag| %>
          <tr><td><%= tag %></td></tr>
          <% end %>
        </table>
      >
      shape = none
      fontname = "Arial"
    ]
    <% end %>

    <% graph_edges.each do |edge| %>
    "<%= edge.from %>" -> "<%= edge.to %>"
    <% end %>

  }
  ERB

  graphviz_input = ERB.new(template).result(binding)
  connected_components_output, status = Open3.capture2("ccomps", "-x", stdin_data: graphviz_input)
  graphviz_output, status = Open3.capture2("dot", "-Tsvg", stdin_data: connected_components_output)
  graphviz_output
end

