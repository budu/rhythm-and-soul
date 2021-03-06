class SpotifyWorker
  include Sidekiq::Worker
  include SidekiqStatus::Worker #this is the sidekiq status module
  sidekiq_options retry: false

  def perform(current_user_id)
    @user = User.find(current_user_id)
    self.total = 100
    at 0
    artists_image_and_genre
  end

  private

  def playlists_ids_parsing(offset)
    at 5
    url = "https://api.spotify.com/v1/users/#{@user.spotify_id}/playlists?limit=50&offset=#{offset}"
    playlists_serialized = RestClient::Resource.new(url, headers: {accept: "application/json", authorization: "Bearer #{@user.auth_token}"})
    @partial_playlist = JSON.parse(playlists_serialized.get)
  end

  def playlists_ids_storing
    playlists_ids_parsing(0)
    at 20
    all_playlists = []
    @partial_playlist["items"].each do |playlist|
      all_playlists << playlist
    end

    if all_playlists.count % 50 != 0
      all_playlists
    else
      i = 50
      until all_playlists.count % 50 != 0
        playlists_ids_parsing(i)
        @partial_playlist["items"].each do |playlist|
          all_playlists << playlist
        end
        i += 50
      end
    end
    unwanted_playlists = all_playlists.map do |playlist|
      if playlist["owner"]["id"] != @user.spotify_id
        playlist
      end
    end
    unwanted_playlists.delete(nil)
    playlists = all_playlists - unwanted_playlists
    @playlists_ids = playlists.map do |playlist|
      playlist["id"]
    end
    return @playlists_ids
  end

  def get_tracks_artists
    tracks = []
    playlists_ids_storing.each do |playlist_id|
      url = "https://api.spotify.com/v1/users/#{@user.spotify_id}/playlists/#{playlist_id}/tracks"
      tracks_serialized = RestClient::Resource.new(url, headers: {accept: "application/json", authorization: "Bearer #{@user.auth_token}"})
      tracks << JSON.parse(tracks_serialized.get)
    end
    at 40
    @names_and_ids = []
    @artists_ids = []
    @artists_names_and_ids = tracks.map do |playlist_tracks|
      playlist = playlist_tracks["items"]
      playlist.each do |track|
        unless track["track"].nil? || track["track"]["artists"][0]["uri"].nil?
          name_and_id = []
          track_artist_name = track["track"]["album"]["artists"][0]["name"]
          track_artist_id = track["track"]["album"]["artists"][0]["id"]
          name_and_id << track_artist_name
          name_and_id << track_artist_id
          @artists_ids << track_artist_id
          @names_and_ids << name_and_id unless @names_and_ids.include?(name_and_id)
        end
      end
    end
    @names_and_ids
  end

  def artists_persistence
    get_tracks_artists
    at 60
    @names_and_ids.each do |artist_array|
      artist = Artist.where(name: artist_array[0])
      unless artist.empty?
        unless @user.artists.include?(artist[0])
          new_user_artist = UserArtist.new()
          new_user_artist.artist = artist[0]
          new_user_artist.user = @user
          new_user_artist.save
        end
      else
        new_artist = Artist.new(name: artist_array[0], spotify_id: artist_array[1])
        new_artist.save
        new_user_artist = UserArtist.new()
        new_user_artist.artist = new_artist
        new_user_artist.user = @user
        new_user_artist.save
      end
    end
    @user.artists.each do |artist|
      unless @artists_ids.include?(artist.spotify_id)
        user_artist_to_destroy = UserArtist.find_by(artist_id: artist.id, user_id: @user.id)
        user_artist_to_destroy.delete
      end
    end
  end

  def artists_image_and_genre
    artists_persistence
    # get_tracks_artists
    at 70
    url = "https://api.spotify.com/v1/artists?ids="
    url_start_split = url.split("")
    i = 0
    j = 49
    @artists_images_genre = []
    while j < @names_and_ids.count + 50
      url_ids = []
      @names_and_ids[i..j].each do |artist|
        url_ids << artist[1]
        url_ids << ","
      end
      url = url_start_split + url_ids
      url.pop
      url = url.join("")
      artists_serialized = RestClient::Resource.new(url, headers: {accept: "application/json", authorization: "Bearer #{@user.auth_token}"})
      artists_parsed = JSON.parse(artists_serialized.get)
      artists_parsed["artists"].each { |artist| @artists_images_genre << artist }
      i += 50
      j += 50
    end
    # @artists_images_genre = @names_and_ids.map do |artist|
    #   url = "https://api.spotify.com/v1/artists/#{artist[1]}"
    #   artists_serialized = RestClient::Resource.new(url, headers: {accept: "application/json", authorization: "Bearer #{@user.auth_token}"})
    #   @artist = JSON.parse(artists_serialized.get)
    # end
    at 80
    @artists_images_genre.each do |a|
      artist_to_update = Artist.where(name: a["name"])[0]
      artist_to_update.update(images: a["images"][0]["url"]) unless a["images"].empty? || Artist.where(name: a["name"])[0].nil? #Needs to be fixed, second condition shouldn't have to exist to prevent 'undefined method `genres'' error
        new_artist_genre = ArtistGenre.new()
      artist_genres = a["genres"]
      unless a["genres"].empty?
        artist_genres.each do |genre_name|
          genre = Genre.where(name: genre_name)
          if genre.exists?
            unless artist_to_update.nil? || artist_to_update.genres.include?(genre[0]) #Needs to be fixed, second condition shouldn't have to exist to prevent 'undefined method `genres'' error
              new_artist_genre = ArtistGenre.new()
              new_artist_genre.genre = genre[0]
              new_artist_genre.artist = artist_to_update
              new_artist_genre.save
            end
          else
            new_genre = Genre.new(name: genre_name)
            new_genre.save
            new_artist_genre = ArtistGenre.new()
            new_artist_genre.genre = new_genre
            new_artist_genre.artist = artist_to_update
            new_artist_genre.save
          end
        end
      end
    end
    at 100
  end
end
