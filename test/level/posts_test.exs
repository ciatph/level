defmodule Level.PostsTest do
  use Level.DataCase, async: true

  alias Level.Groups
  alias Level.Groups.Group
  alias Level.Posts
  alias Level.Posts.Post
  alias Level.Posts.PostView
  alias Level.Posts.Reply
  alias Level.Spaces.SpaceUser

  describe "posts_base_query/1 with users" do
    setup do
      {:ok, %{space_user: space_user} = result} = create_user_and_space()
      {:ok, %{group: group}} = create_group(space_user)
      {:ok, Map.put(result, :group, group)}
    end

    test "should not include posts not in the user's spaces", %{
      space_user: space_user,
      group: group
    } do
      {:ok, %{post: %Post{id: post_id}}} = create_post(space_user, group)
      {:ok, outside_user} = create_user()

      result =
        outside_user
        |> Posts.posts_base_query()
        |> Repo.get_by(id: post_id)

      assert result == nil
    end

    test "should not include posts not in private groups the user cannot access", %{
      space: space,
      space_user: space_user,
      group: group
    } do
      {:ok, group} = Groups.update_group(group, %{is_private: true})
      {:ok, %{post: %Post{id: post_id}}} = create_post(space_user, group)
      {:ok, %{user: another_user}} = create_space_member(space)

      result =
        another_user
        |> Posts.posts_base_query()
        |> Repo.get_by(id: post_id)

      assert result == nil
    end

    test "should include posts not in private groups the user can access", %{
      space: space,
      space_user: space_user,
      group: group
    } do
      {:ok, group} = Groups.update_group(group, %{is_private: true})
      {:ok, %{post: %Post{id: post_id}}} = create_post(space_user, group)
      {:ok, %{user: another_user, space_user: another_space_user}} = create_space_member(space)
      {:ok, _} = Groups.create_group_membership(group, another_space_user)

      assert %Post{id: ^post_id} =
               another_user
               |> Posts.posts_base_query()
               |> Repo.get_by(id: post_id)
    end

    test "should include posts not in public groups", %{
      space: space,
      space_user: space_user,
      group: group
    } do
      {:ok, %{post: %Post{id: post_id}}} = create_post(space_user, group)
      {:ok, %{user: another_user}} = create_space_member(space)

      assert %Post{id: ^post_id} =
               another_user
               |> Posts.posts_base_query()
               |> Repo.get_by(id: post_id)
    end
  end

  describe "create_post/2" do
    setup do
      {:ok, %{space_user: space_user} = result} = create_user_and_space()
      {:ok, %{group: group}} = create_group(space_user)
      {:ok, Map.put(result, :group, group)}
    end

    test "creates a new post given valid params", %{space_user: space_user, group: group} do
      params = valid_post_params() |> Map.merge(%{body: "The body"})
      {:ok, %{post: post}} = Posts.create_post(space_user, group, params)
      assert post.space_user_id == space_user.id
      assert post.body == "The body"
    end

    test "puts the post in the given group", %{
      space_user: space_user,
      group: %Group{id: group_id} = group
    } do
      params = valid_post_params()
      {:ok, %{post: post}} = Posts.create_post(space_user, group, params)

      post = Repo.preload(post, :groups)
      assert [%Group{id: ^group_id} | _] = post.groups
    end

    test "subscribes the user to the post", %{space_user: space_user, group: group} do
      params = valid_post_params()
      {:ok, %{post: post}} = Posts.create_post(space_user, group, params)
      assert :subscribed = Posts.get_subscription_state(post, space_user)
    end

    test "logs the event", %{space_user: space_user, group: group} do
      params = valid_post_params()
      {:ok, %{post: post, log: log}} = Posts.create_post(space_user, group, params)
      assert log.event == "POST_CREATED"
      assert log.actor_id == space_user.id
      assert log.group_id == group.id
      assert log.post_id == post.id
    end

    test "record mentions", %{space: space, space_user: space_user, group: group} do
      {:ok, %{space_user: %SpaceUser{id: mentioned_id}}} =
        create_space_member(space, %{handle: "tiff"})

      params = valid_post_params() |> Map.merge(%{body: "Hey @tiff"})

      assert {:ok, %{mentions: [^mentioned_id]}} = Posts.create_post(space_user, group, params)
    end

    test "returns errors given invalid params", %{space_user: space_user, group: group} do
      params = valid_post_params() |> Map.merge(%{body: nil})
      {:error, :post, changeset, _} = Posts.create_post(space_user, group, params)

      assert %Ecto.Changeset{errors: [body: {"can't be blank", [validation: :required]}]} =
               changeset
    end
  end

  describe "subscribe/2" do
    setup do
      {:ok, %{space_user: space_user} = result} = create_user_and_space()
      {:ok, %{group: group}} = create_group(space_user)
      {:ok, %{post: post}} = create_post(space_user, group)
      {:ok, Map.merge(result, %{group: group, post: post})}
    end

    test "subscribes the user to the post", %{
      space: space,
      post: post
    } do
      {:ok, %{space_user: another_space_user}} = create_space_member(space)
      :ok = Posts.subscribe(post, another_space_user)
      assert :subscribed = Posts.get_subscription_state(post, another_space_user)
    end

    test "ignores repeated subscribes", %{space_user: space_user, post: post} do
      assert :subscribed = Posts.get_subscription_state(post, space_user)
      assert :ok = Posts.subscribe(post, space_user)
    end
  end

  describe "create_reply/2" do
    setup do
      {:ok, %{space_user: space_user} = result} = create_user_and_space()
      {:ok, %{group: group}} = create_group(space_user)
      {:ok, %{post: post}} = create_post(space_user, group)
      {:ok, Map.merge(result, %{group: group, post: post})}
    end

    test "creates a new reply given valid params", %{space_user: space_user, post: post} do
      params = valid_reply_params() |> Map.merge(%{body: "The body"})
      {:ok, %{reply: reply}} = Posts.create_reply(space_user, post, params)
      assert reply.space_user_id == space_user.id
      assert reply.body == "The body"
    end

    test "subscribes the user to the post", %{space_user: space_user, post: post} do
      :ok = Posts.unsubscribe(post, space_user)
      params = valid_reply_params()
      {:ok, %{reply: _reply}} = Posts.create_reply(space_user, post, params)
      assert :subscribed = Posts.get_subscription_state(post, space_user)
    end

    test "logs the event", %{space_user: space_user, post: post, group: group} do
      params = valid_reply_params()
      {:ok, %{reply: reply, log: log}} = Posts.create_reply(space_user, post, params)
      assert log.event == "REPLY_CREATED"
      assert log.actor_id == space_user.id
      assert log.group_id == group.id
      assert log.post_id == post.id
      assert log.reply_id == reply.id
    end

    test "records a view", %{space_user: space_user, post: post} do
      params = valid_reply_params()
      {:ok, %{reply: reply, post_view: post_view}} = Posts.create_reply(space_user, post, params)
      assert post_view.post_id == post.id
      assert post_view.last_viewed_reply_id == reply.id
    end

    test "returns errors given invalid params", %{space_user: space_user, post: post} do
      params = valid_reply_params() |> Map.merge(%{body: nil})
      {:error, :reply, changeset, _} = Posts.create_reply(space_user, post, params)

      assert %Ecto.Changeset{errors: [body: {"can't be blank", [validation: :required]}]} =
               changeset
    end
  end

  describe "record_view/3" do
    setup do
      {:ok, %{space_user: space_user} = result} = create_user_and_space()
      {:ok, %{group: group}} = create_group(space_user)
      {:ok, %{post: post}} = create_post(space_user, group)
      {:ok, Map.merge(result, %{group: group, post: post})}
    end

    test "creates a post view record with last viewed reply", %{
      space_user: space_user,
      post: post
    } do
      {:ok, %{reply: %Reply{id: reply_id} = reply}} = create_reply(space_user, post)

      assert {:ok, %PostView{last_viewed_reply_id: ^reply_id}} =
               Posts.record_view(post, space_user, reply)
    end
  end

  describe "record_view/2" do
    setup do
      {:ok, %{space_user: space_user} = result} = create_user_and_space()
      {:ok, %{group: group}} = create_group(space_user)
      {:ok, %{post: post}} = create_post(space_user, group)
      {:ok, Map.merge(result, %{group: group, post: post})}
    end

    test "creates a post view record with null last viewed reply", %{
      space_user: space_user,
      post: post
    } do
      assert {:ok, %PostView{last_viewed_reply_id: nil}} = Posts.record_view(post, space_user)
    end
  end
end
