defmodule Mobilizon.Users.LockedProfile do
  @moduledoc """
  Locked profiles.

  With `lock_profiles` enabled, every non-admin account has exactly one profile whose
  username and display name are both derived from the part of the account email before
  the `@`. The profile is created on the first login (local, LDAP or OAuth), and its
  display name is reset to the username on every login, so it can't be used to
  impersonate someone else.
  """

  alias Mobilizon.{Actors, Config, Users}
  alias Mobilizon.Actors.Actor
  alias Mobilizon.Federation.ActivityPub.Actions
  alias Mobilizon.Users.User

  import Mobilizon.Users.Guards
  require Logger

  @spec enabled?() :: boolean()
  def enabled?, do: Config.instance_lock_profiles?()

  @doc """
  Whether the profiles of this user are locked.
  """
  @spec locked?(User.t()) :: boolean()
  def locked?(%User{role: role}) when is_admin(role), do: false
  def locked?(%User{}), do: enabled?()

  @doc """
  The profile username for an email: its local part, lowercased, with every character
  other than `a-z`, `0-9` and `_` replaced by `_`.
  """
  @spec username_for(String.t()) :: String.t()
  def username_for(email) do
    email
    |> String.split("@")
    |> hd()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]/, "_")
  end

  @doc """
  Whether a new account with this email would get a username that is already taken.
  """
  @spec username_taken?(String.t()) :: boolean()
  def username_taken?(email) do
    enabled?() and not is_nil(Actors.get_local_actor_by_name(username_for(email)))
  end

  @doc """
  Creates the locked profile of an account that has none, and resets the display name
  of its profiles to their username.
  """
  @spec ensure(User.t()) :: :ok | {:error, :profile_username_taken}
  def ensure(%User{} = user) do
    if locked?(user), do: do_ensure(user), else: :ok
  end

  defp do_ensure(%User{id: user_id, email: email} = user) do
    case Users.get_actors_for_user(user) do
      [] ->
        username = username_for(email)

        case Actors.new_person(
               %{preferred_username: username, name: username, user_id: user_id},
               true
             ) do
          {:ok, %Actor{}} ->
            :ok

          {:error, err} ->
            Logger.warning(
              "Unable to create the locked profile \"#{username}\" for user #{user_id}: #{inspect(err)}"
            )

            {:error, :profile_username_taken}
        end

      actors ->
        Enum.each(actors, &sync_name/1)
    end
  end

  defp sync_name(%Actor{preferred_username: username, name: username}), do: :ok

  defp sync_name(%Actor{preferred_username: username} = actor) do
    Actions.Update.update(actor, %{name: username}, true)
    :ok
  end
end
