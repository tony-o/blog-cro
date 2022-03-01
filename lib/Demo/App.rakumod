unit module Demo::App;

use Cro::HTTP::Router;
use Cro::HTTP::Server;
use Cro::HTTP::Session::InMemory;
use Cro::WebApp::Template;
use Cro::Uri :encode-percents;
use HTTP::Tinyish;
use JSON::Fast;
use DB::SQLite;
use UUID;

use Config;

class SessionVar does Cro::HTTP::Auth {
  has $.user         is rw;
  has $.user-id      is rw;
  has $.login-state  is rw;
}

my $client      = HTTP::Tinyish.new;
my $db          = DB::SQLite.new(filename => %?RESOURCES<db.sqlite>.absolute);


sub build-post-hierarchy(Str:D $id) {
  my %post    = $db.query('select p.id, p.title, p.body, u.name from posts p left join users u on u.id = p.author where p.id = ?;', $id).hash;
  my $sql     = q:to/EOSQL/;
with recursive threads(level,id,title,parent) as (
	select 0, id, title, parent from posts where id = (
	  with recursive parents(id,parent) as (
        select id, parent from posts where id = ?
        union all
        select p.id, p.parent from posts p, parents where p.id = parents.parent
	  ) select id from parents where parent is null
	)
	union all 
	select level+1, p.id, p.title, p.parent from posts p, threads where p.parent = threads.id
) select * from threads order by level, parent;
EOSQL

  if (%post<id>//'') ne $id {
    return Nil
  }
  my @threads = $db.query($sql, $id).hashes;
  my %indexes;
  my @levels;
  for @threads -> $t {
    if %indexes{$t<parent>//''} {
      @levels.splice(%indexes{$t<parent>}, 0, { id => $t<id>, title => $t<title>, (level => '&nbsp' x $t<level> * 4) });
      for %indexes.keys -> $k {
        %indexes{$k}++ if %indexes{$t<parent>} < %indexes{$k};
      }
      %indexes{$t<id>} = %indexes{$t<parent>} + 1;
    } else {
      @levels.push({ id => $t<id>, title => $t<title>, level => ('&nbsp;' x $t<level> * 4) });
      %indexes{$t<id>} = @levels.elems;
    }
  }
  return {:%post, :@levels};
}

my $application = route {
  template-location 'templates/';

  before Cro::HTTP::Session::InMemory[SessionVar].new(
    expiration  => Duration.new(60*60),
    cookie-name => 'demo-app',
  );

  get -> SessionVar \session {
    template 'main.crotmp', {
      user      => session.user,
      posts     => $db.query('select id, title from posts where parent is null').hashes,
      logged-in => (session.user-id ?? True !! False),
    };
  }

  subset LoggedIn of SessionVar where *.user-id.defined ?? True !! False;
  get -> LoggedIn \session, 'post' {
    redirect '/oauth' unless session.user-id;
    template 'post.crotmp', { title => '', body => '', errors => [] };
  }
  post -> LoggedIn \session, 'post' {
    redirect '/oauth' unless session.user-id;
    request-body -> (:$title, :$body) {
      my @errors;
      @errors.push('Title cannot be fewer than five characters') if $title.chars <= 5;
      @errors.push('Post cannot be fewer than fifty characters') if $body.chars <= 50;

      if @errors {
        template 'post.crotmp', {
          :$title,
          :$body,
          :@errors,
        };
        last;
      }

      
      my $id = UUID.new.Str;
      my $ok = $db.query('insert into posts (id, title, body, author) values (?, ?, ?, ?);', $id, $title, $body, session.user-id);
      if $ok {
        redirect :see-other, "/view/{$id}";
      } else {
        @errors.push('An error occurred while saving your post, please try again later');
        template 'post.crotmp', { :$title, :$body, :@errors };
      }
    }
  }

  get -> SessionVar \session, 'view', $id {
    my $data = build-post-hierarchy($id);
    if !$data {
      redirect '/';
    } else {
      template 'view.crotmp', {
        :post($data<post>),
        :levels($data<levels>),
        response => {title => '', body => '', parent => $id, errors => [] },
        logged-in => (session.user-id ?? True !! False),
      };
    }
  }

  post -> SessionVar \session, 'view', $id {
    my $data = build-post-hierarchy($id);
    if !$data {
      redirect '/';
    } else {
      request-body -> (:$title, :$body) {
        my @errors;
        @errors.push('Title cannot be fewer than five characters') if $title.chars <= 5;
        @errors.push('Post cannot be fewer than fifty characters') if $body.chars <= 50;

        if @errors {
          template 'view.crotmp', {
            :post($data<post>),
            :levels($data<levels>),
            response => {title => $title, body => $body, parent => $id, errors => [] },
            logged-in => (session.user-id ?? True !! False),
            :@errors,
          };
        } else {
          my $rid = UUID.new.Str;
          my $ok = $db.query('insert into posts (id, title, body, author, parent) values (?, ?, ?, ?, ?);', $rid, $title, $body, session.user-id, $id);
          if $ok {
            redirect :see-other, "/view/{$rid}";
          } else {
            @errors.push('An error occurred while saving your post, please try again later');
            template 'view.crotmp', {
              :post($data<post>),
              :levels($data<levels>),
              response => {title => $title, body => $body, parent => $id, errors => @errors },
              logged-in => (session.user-id ?? True !! False),
              :@errors,
            };
          }
        }
      }
    }
  }

  get -> SessionVar \session, 'oauth' {
    session.login-state = ('a' .. 'z').pick(24).sort.join('');
    redirect 'https://github.com/login/oauth/authorize'
           ~ "?client_id={encode-percents: config<gh-client>}"
           ~ "&redirect_uri={encode-percents: "http://localhost:8666/oauth2"}"
           ~ "&state={encode-percents: session.login-state}";
  }

  get -> SessionVar \session, 'oauth2', :$state! is query, Str :$code! is query, :$error? is query {
    redirect '/' if $error.defined;
    my $resp = $client.post(
      headers => {Accept => 'application/json'},
      'https://github.com/login/oauth/access_token'
      ~ "?client_id={encode-percents: config<gh-client> }"
      ~ "&client_secret={encode-percents: config<gh-secret> }"
      ~ "&code={encode-percents: $code }",
    );
    redirect '/' unless 200 <= $resp<status> <= 201;
    redirect '/?error=state-mismatch' unless $state eq session.login-state;

    # Now get the user info so we can create a user
    my $json = from-json($resp<content>);
    $resp = $client.get(
      headers => {Authorization => "token {$json<access_token>}"},
      "https://api.github.com/user",
    );
    $json = from-json($resp<content>);

    # determine if user exists
    my $user = $db.query('select * from users where foreign_id = ?',  $json<id>).hash;
    if ($user<foreign_id>//'') ne $json<id> {
      # create them
      my $id = UUID.new.Str;
      $db.query('insert into users (id, name, foreign_id) values (?, ?, ?);', $id, $json<name>, $json<id>);
      $user = $db.query('select * from users where id = ?',  $id).hash;
    }

    # if the db failed for whatever reason, don't set the user session
    if ($user<foreign_id>//'') eq $json<id> {
      session.user = $user;
      session.user-id = $user<id>;
    }
    redirect '/';
  }

}

my $host = config<listen-ip>   // '0.0.0.0';
my $port = config<listen-port> // 10000;

my Cro::Service $service = Cro::HTTP::Server.new(:$host, :$port, :$application);

$service.start;

say "Listening: $host:$port";

react whenever signal(SIGINT) {
  $service.stop;
  exit;
}
