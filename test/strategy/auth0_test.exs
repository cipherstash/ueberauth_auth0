defmodule Ueberauth.Strategy.Auth0Test do
  # Test resources:
  use ExUnit.Case, async: true
  use ExVCR.Mock, adapter: ExVCR.Adapter.Hackney

  use Plug.Test

  # Custom data:
  import Ueberauth.Strategy.Auth0, only: [info: 1, extra: 1]
  alias Ueberauth.Auth.{Extra, Info}

  # Initializing utils:
  doctest Ueberauth.Strategy.Auth0

  @router SpecRouter.init([])
  @test_email "janedoe@example.com"
  @session_options Plug.Session.init(
                     store: Plug.Session.COOKIE,
                     key: "_my_key",
                     signing_salt: "CXlmrshG"
                   )

  # Setups:
  setup_all do
    # Creating token:
    token = %OAuth2.AccessToken{
      access_token: "eyJz93alolk4laUWw",
      expires_at: 1_592_551_369,
      other_params: %{"id_token" => "eyJ0XAipop4faeEoQ"},
      refresh_token: "GEbRxBNkitedjnXbL",
      token_type: "Bearer"
    }

    # Read the fixture with the user information:
    {:ok, json} =
      "test/fixtures/auth0.json"
      |> Path.expand()
      |> File.read()

    user_info = Jason.decode!(json)

    {:ok,
     %{
       user_info: user_info,
       token: token
     }}
  end

  # Tests:
  describe "handle_request!" do
    test "simple oauth2 /authorize request" do
      conn =
        :get
        |> conn("/auth/auth0")
        |> SpecRouter.call(@router)

      assert conn.resp_body =~ ~s|<html><body>You are being <a href=|
      assert conn.resp_body =~ ~s|>redirected</a>.</body></html>|
      assert conn.resp_body =~ ~s|href="https://example-app.auth0.com/authorize?|
      assert conn.resp_body =~ ~s|client_id=clientidsomethingrandom|

      assert conn.resp_body =~
               ~s|redirect_uri=http%3A%2F%2Fwww.example.com%2Fauth%2Fauth0%2Fcallback|

      assert conn.resp_body =~ ~s|response_type=code|
      assert conn.resp_body =~ ~s|scope=openid+profile+email|
      assert conn.resp_body =~ ~s|state=#{conn.private[:ueberauth_state_param]}|
    end

    test "advanced oauth2 /authorize request" do
      conn =
        :get
        |> conn(
          "/auth/auth0?scope=profile%20address%20phone&audience=https%3A%2F%2Fexample-app.auth0.com%2Fmfa%2F" <>
            "&connection=facebook&unknown_param=should_be_ignored" <>
            "&prompt=login&screen_hint=signup&login_hint=user%40example.com" <>
            "&organization=org_abc123&invitation=INVITE2022"
        )
        |> SpecRouter.call(@router)

      assert conn.resp_body =~ ~s|<html><body>You are being <a href=|
      assert conn.resp_body =~ ~s|>redirected</a>.</body></html>|
      assert conn.resp_body =~ ~s|href="https://example-app.auth0.com/authorize?|
      assert conn.resp_body =~ ~s|client_id=clientidsomethingrandom|
      assert conn.resp_body =~ ~s|connection=facebook|
      assert conn.resp_body =~ ~s|login_hint=user|
      assert conn.resp_body =~ ~s|screen_hint=signup|

      assert conn.resp_body =~
               ~s|redirect_uri=http%3A%2F%2Fwww.example.com%2Fauth%2Fauth0%2Fcallback|

      assert conn.resp_body =~ ~s|response_type=code|
      assert conn.resp_body =~ ~s|scope=profile+address+phone|
      assert conn.resp_body =~ ~s|state=#{conn.private[:ueberauth_state_param]}|
      assert conn.resp_body =~ ~s|organization=org_abc123|
      assert conn.resp_body =~ ~s|invitation=INVITE2022|
    end

    test "hacky parameter test" do
      conn =
        :get
        |> conn("/auth/auth0?v=foo&via=bar&product=baz")
        |> SpecRouter.call(@router)

      assert conn.resp_body =~
               ~s|redirect_uri=http%3A%2F%2Fwww.example.com%2Fauth%2Fauth0%2Fcallback%3Fproduct%3Dbaz%26v%3Dfoo%26via%3Dbar|
    end

  end

  describe "handle_callback!" do
    test "nominal callback from auth0" do
      request_conn =
        :get
        |> conn("/auth/auth0", id: "foo")
        |> SpecRouter.call(@router)
        |> Plug.Conn.fetch_cookies()

      state = request_conn.private[:ueberauth_state_param]
      code = "some_code"

      use_cassette "auth0-ok-response", match_requests_on: [:query] do
        conn =
          :get
          |> conn("/auth/auth0/callback",
            id: "foo",
            code: code,
            state: state
          )
          |> Map.put(:cookies, request_conn.cookies)
          |> Map.put(:req_cookies, request_conn.req_cookies)
          |> Plug.Session.call(@session_options)
          |> SpecRouter.call(@router)

        assert conn.resp_body == "auth0 callback"

        auth = conn.assigns.ueberauth_auth

        assert auth.provider == :auth0
        assert auth.strategy == Ueberauth.Strategy.Auth0
        assert auth.uid == "auth0|lyy5v5utb6n9qfm4ihi3l7pv34po66"
        assert conn.private.auth0_state == state

        ## Tokens have expiration time (see other test below)
        assert auth.credentials.expires == true
        assert is_integer(auth.credentials.expires_at)
        assert auth.credentials.scopes == ["openid", "profile", "email"]
      end
    end

    test "nominal callback from auth0 but without state: potential CSRF attack" do
      request_conn =
        :get
        |> conn("/auth/auth0", id: "foo")
        |> SpecRouter.call(@router)
        |> Plug.Conn.fetch_cookies()

      code = "some_code"

      use_cassette "auth0-ok-response", match_requests_on: [:query] do
        conn =
          :get
          |> conn("/auth/auth0/callback",
            id: "foo",
            code: code
          )
          |> Map.put(:cookies, request_conn.cookies)
          |> Map.put(:req_cookies, request_conn.req_cookies)
          |> Plug.Session.call(@session_options)
          |> SpecRouter.call(@router)

        assert conn.resp_body == "auth0 callback"

        auth = conn.assigns.ueberauth_failure
        assert conn.private[:auth0_state] == nil

        csrf_attack = %Ueberauth.Failure.Error{
          message: "Cross-Site Request Forgery attack",
          message_key: "csrf_attack"
        }

        assert auth.provider == :auth0
        assert auth.strategy == Ueberauth.Strategy.Auth0
        assert auth.errors == [csrf_attack]
      end
    end

    test "invalid callback from auth0 without code" do
      request_conn =
        :get
        |> conn("/auth/auth0", id: "foo")
        |> SpecRouter.call(@router)
        |> Plug.Conn.fetch_cookies()

      state = request_conn.private[:ueberauth_state_param]

      use_cassette "auth0-ok-response", match_requests_on: [:query] do
        conn =
          :get
          |> conn("/auth/auth0/callback",
            id: "foo",
            state: state
          )
          |> Map.put(:cookies, request_conn.cookies)
          |> Map.put(:req_cookies, request_conn.req_cookies)
          |> Plug.Session.call(@session_options)
          |> SpecRouter.call(@router)

        assert conn.resp_body == "auth0 callback"

        auth = conn.assigns.ueberauth_failure

        missing_code_error = %Ueberauth.Failure.Error{
          message: "No code received",
          message_key: "missing_code"
        }

        assert auth.provider == :auth0
        assert auth.strategy == Ueberauth.Strategy.Auth0
        assert auth.errors == [missing_code_error]
      end
    end

    test "invalid callback from auth0 with invalid code" do
      request_conn =
        :get
        |> conn("/auth/auth0", id: "foo")
        |> SpecRouter.call(@router)
        |> Plug.Conn.fetch_cookies()

      state = request_conn.private[:ueberauth_state_param]

      use_cassette "auth0-invalid-code", match_requests_on: [:query] do
        conn =
          :get
          |> conn("/auth/auth0/callback", id: "foo", code: "invalid_code", state: state)
          |> Map.put(:cookies, request_conn.cookies)
          |> Map.put(:req_cookies, request_conn.req_cookies)
          |> Plug.Session.call(@session_options)
          |> SpecRouter.call(@router)

        auth = conn.assigns.ueberauth_failure

        invalid_grant_error = %Ueberauth.Failure.Error{
          message: "Invalid authorization code",
          message_key: "invalid_grant"
        }

        assert auth.provider == :auth0
        assert auth.strategy == Ueberauth.Strategy.Auth0
        assert auth.errors == [invalid_grant_error]
      end
    end

    test "invalid callback from auth0 with no token in response" do
      request_conn =
        :get
        |> conn("/auth/auth0", id: "foo")
        |> SpecRouter.call(@router)
        |> Plug.Conn.fetch_cookies()

      state = request_conn.private[:ueberauth_state_param]

      use_cassette "auth0-no-access-token", match_requests_on: [:query] do
        conn =
          :get
          |> conn("/auth/auth0/callback",
            id: "foo",
            code: "some_code",
            state: state
          )
          |> Map.put(:cookies, request_conn.cookies)
          |> Map.put(:req_cookies, request_conn.req_cookies)
          |> Plug.Session.call(@session_options)
          |> SpecRouter.call(@router)

        assert conn.resp_body == "auth0 callback"

        auth = conn.assigns.ueberauth_failure

        missing_code_error = %Ueberauth.Failure.Error{
          message: "Something went wrong",
          message_key: "something_wrong"
        }

        assert auth.provider == :auth0
        assert auth.strategy == Ueberauth.Strategy.Auth0
        assert auth.errors == [missing_code_error]
      end
    end

    test "callback from auth0 with no expiration time of tokens" do
      request_conn =
        :get
        |> conn("/auth/auth0", id: "foo")
        |> SpecRouter.call(@router)
        |> Plug.Conn.fetch_cookies()

      state = request_conn.private[:ueberauth_state_param]

      use_cassette "auth0-token-doesnt-expire", match_requests_on: [:query] do
        conn =
          :get
          |> conn("/auth/auth0/callback",
            id: "foo",
            code: "some_code",
            state: state
          )
          |> Map.put(:cookies, request_conn.cookies)
          |> Map.put(:req_cookies, request_conn.req_cookies)
          |> Plug.Session.call(@session_options)
          |> SpecRouter.call(@router)

        assert conn.resp_body == "auth0 callback"

        auth = conn.assigns.ueberauth_auth

        # Same information as default token
        assert auth.provider == :auth0
        assert auth.strategy == Ueberauth.Strategy.Auth0
        assert auth.uid == "auth0|lyy5v5utb6n9qfm4ihi3l7pv34po66"
        assert conn.private.auth0_state == state

        ## Difference here
        assert auth.credentials.expires == false
        assert auth.credentials.expires_at == nil
      end
    end
  end

  test "/userinfo call with unauthorized access token" do
    request_conn =
      :get
      |> conn("/auth/auth0", id: "foo")
      |> SpecRouter.call(@router)
      |> Plug.Conn.fetch_cookies()

    state = request_conn.private[:ueberauth_state_param]
    code = "some_code"

    use_cassette "auth0-userinfo-invalid-access-token", match_requests_on: [:query] do
      conn =
        :get
        |> conn("/auth/auth0/callback",
          id: "foo",
          code: code,
          state: state
        )
        |> Map.put(:cookies, request_conn.cookies)
        |> Map.put(:req_cookies, request_conn.req_cookies)
        |> Plug.Session.call(@session_options)
        |> SpecRouter.call(@router)

      assert conn.resp_body == "auth0 callback"

      auth = conn.assigns.ueberauth_failure

      token_unauthorized = %Ueberauth.Failure.Error{
        message: "unauthorized_token",
        message_key: "OAuth2"
      }

      assert auth.provider == :auth0
      assert auth.strategy == Ueberauth.Strategy.Auth0
      assert auth.errors == [token_unauthorized]
    end
  end

  test "/userinfo call with body containing error details" do
    request_conn =
      :get
      |> conn("/auth/auth0", id: "foo")
      |> SpecRouter.call(@router)
      |> Plug.Conn.fetch_cookies()

    state = request_conn.private[:ueberauth_state_param]
    code = "some_code"

    use_cassette "auth0-userinfo-with-errors-in-body", match_requests_on: [:query] do
      conn =
        :get
        |> conn("/auth/auth0/callback",
          id: "foo",
          code: code,
          state: state
        )
        |> Map.put(:cookies, request_conn.cookies)
        |> Map.put(:req_cookies, request_conn.req_cookies)
        |> Plug.Session.call(@session_options)
        |> SpecRouter.call(@router)

      assert conn.resp_body == "auth0 callback"

      auth = conn.assigns.ueberauth_failure

      some_error_in_body = %Ueberauth.Failure.Error{
        message: %{"error" => "something_wrong", "error_description" => "Something went wrong"},
        message_key: "OAuth2"
      }

      assert auth.provider == :auth0
      assert auth.strategy == Ueberauth.Strategy.Auth0
      assert auth.errors == [some_error_in_body]
    end
  end

  describe "info/1" do
    test "user information parsing", fixtures do
      user_info = fixtures.user_info
      token = fixtures.token

      conn = %Plug.Conn{
        private: %{
          auth0_user: user_info,
          auth0_token: token
        }
      }

      assert info(conn) == %Info{
               birthday: "1972-03-31",
               description: nil,
               email: @test_email,
               first_name: "Jane",
               image: "http://example.com/janedoe/me.jpg",
               last_name: "Doe",
               location: nil,
               name: "Jane Josephine Doe",
               nickname: "JJ",
               phone: "+1 (111) 222-3434",
               urls: %{
                 profile: "http://example.com/janedoe",
                 website: "http://example.com"
               }
             }
    end
  end

  describe "extra/1" do
    test "user extra information parsing", fixtures do
      user_info = fixtures.user_info
      token = fixtures.token

      conn = %Plug.Conn{
        private: %{
          auth0_user: user_info,
          auth0_token: token
        }
      }

      assert extra(conn) == %Extra{
               raw_info: %{
                 token: %OAuth2.AccessToken{
                   access_token: "eyJz93alolk4laUWw",
                   expires_at: 1_592_551_369,
                   other_params: %{"id_token" => "eyJ0XAipop4faeEoQ"},
                   refresh_token: "GEbRxBNkitedjnXbL",
                   token_type: "Bearer"
                 },
                 user: %{
                   "address" => %{"country" => "us"},
                   "birthdate" => "1972-03-31",
                   "email" => "janedoe@example.com",
                   "email_verified" => true,
                   "family_name" => "Doe",
                   "gender" => "female",
                   "given_name" => "Jane",
                   "locale" => "en-US",
                   "middle_name" => "Josephine",
                   "name" => "Jane Josephine Doe",
                   "nickname" => "JJ",
                   "phone_number" => "+1 (111) 222-3434",
                   "phone_number_verified" => false,
                   "picture" => "http://example.com/janedoe/me.jpg",
                   "preferred_username" => "j.doe",
                   "profile" => "http://example.com/janedoe",
                   "sub" => "auth0|lyy5v452u345tbn943qf",
                   "updated_at" => "1556845729",
                   "website" => "http://example.com",
                   "zoneinfo" => "America/Los_Angeles"
                 }
               }
             }
    end
  end
end
