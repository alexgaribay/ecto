Code.require_file "../../../integration_test/support/types.exs", __DIR__

defmodule Ecto.Query.SubqueryTest do
  use ExUnit.Case, async: true

  import Ecto.Query

  alias Ecto.Query.Planner
  alias Ecto.Query.JoinExpr

  defmodule Comment do
    use Ecto.Schema

    schema "comments" do
      field :text, :string
      field :temp, :string, virtual: true
      belongs_to :post, Ecto.Query.SubqueryTest.Post
      has_many :post_comments, through: [:post, :comments]
    end
  end

  defmodule Post do
    use Ecto.Schema

    @primary_key {:id, Custom.Permalink, []}
    schema "posts" do
      field :title, :string, source: :post_title
      field :text, :string
      has_many :comments, Ecto.Query.SubqueryTest.Comment
    end
  end

  defp prepare(query, operation \\ :all) do
    Planner.prepare(query, operation, Ecto.TestAdapter, 0)
  end

  defp normalize(query, operation \\ :all) do
    normalize_with_params(query, operation) |> elem(0)
  end

  defp normalize_with_params(query, operation \\ :all) do
    {query, params, _key} = prepare(query, operation)
    {query, _} =
      query
      |> Planner.ensure_select(operation == :all)
      |> Planner.normalize(operation, Ecto.TestAdapter, 0)
    {query, params}
  end

  defp select_fields(fields, ix) do
    for field <- fields do
      {{:., [], [{:&, [], [ix]}, field]}, [], []}
    end
  end

  test "prepare: subqueries" do
    {query, params, key} = prepare(from(subquery(Post), []))
    assert %{query: %Ecto.Query{}, params: []} = query.from
    assert params == []
    assert key == [:all, 0, [:all, 0, {"posts", Post, 127044068}]]

    posts = from(p in Post, where: p.title == ^"hello")
    query = from(c in Comment, join: p in subquery(posts), on: c.post_id == p.id)
    {query, params, key} = prepare(query, [])
    assert {"comments", Comment} = query.from
    assert [%{source: %{query: %Ecto.Query{}, params: ["hello"]}}] = query.joins
    assert params == ["hello"]
    assert [[], 0, {:join, [{:inner, [:all|_], _}]}, {"comments", _, _}] = key
  end

  test "prepare: subqueries with association joins" do
    {query, _, _} = prepare(from(p in subquery(Post), join: c in assoc(p, :comments)))
    assert [%{source: {"comments", Comment}}] = query.joins

    message = ~r/can only perform association joins on subqueries that return a source with schema in select/
    assert_raise Ecto.QueryError, message, fn ->
      prepare(from(p in subquery(from p in Post, select: p.title), join: c in assoc(p, :comments)))
    end
  end

  test "prepare: subqueries with map updates in select can be used with assoc" do
    query =
      Post
      |> select([post], %{post | title: ^"hello"})
      |> subquery()
      |> join(:left, [subquery_post], comment in assoc(subquery_post, :comments))
      |> prepare()
      |> elem(0)

    assert %JoinExpr{on: on, source: source, assoc: nil, qual: :left} = hd(query.joins)
    assert source == {"comments", Comment}
    assert Macro.to_string(on.expr) == "&1.post_id() == &0.id()"
  end

  test "prepare: subqueries do not support preloads" do
    query = from p in Post, join: c in assoc(p, :comments), preload: [comments: c]
    assert_raise Ecto.SubQueryError, ~r/cannot preload associations in subquery/, fn ->
      prepare(from(subquery(query), []))
    end
  end

  describe "prepare: subqueries select" do
    test "supports implicit select" do
      query = prepare(from(subquery(Post), [])) |> elem(0)
      assert "%Ecto.Query.SubqueryTest.Post{id: &0.id(), title: &0.title(), " <>
             "text: &0.text()}" =
             Macro.to_string(query.from.query.select.expr)
    end

    test "supports field selector" do
      query = from p in "posts", select: p.text
      query = prepare(from(subquery(query), [])) |> elem(0)
      assert "%{text: &0.text()}" =
             Macro.to_string(query.from.query.select.expr)

      query = from p in Post, select: p.text
      query = prepare(from(subquery(query), [])) |> elem(0)
      assert "%{text: &0.text()}" =
             Macro.to_string(query.from.query.select.expr)
    end

    test "supports maps" do
      query = from p in Post, select: %{text: p.text}
      query = prepare(from(subquery(query), [])) |> elem(0)
      assert "%{text: &0.text()}" =
             Macro.to_string(query.from.query.select.expr)
    end

    test "supports structs" do
      query = from p in Post, select: %Post{text: p.text}
      query = prepare(from(subquery(query), [])) |> elem(0)
      assert "%Ecto.Query.SubqueryTest.Post{text: &0.text()}" =
             Macro.to_string(query.from.query.select.expr)
    end

    test "supports update in maps" do
      query = from p in Post, select: %{p | text: p.title}
      query = prepare(from(subquery(query), [])) |> elem(0)
      assert "%Ecto.Query.SubqueryTest.Post{id: &0.id(), title: &0.title(), " <>
             "text: &0.title()}" =
             Macro.to_string(query.from.query.select.expr)

      query = from p in Post, select: %{p | unknown: p.title}
      assert_raise Ecto.SubQueryError, ~r/invalid key `:unknown` on map update in subquery/, fn ->
        prepare(from(subquery(query), []))
      end
    end

    test "supports merge" do
      query = from p in Post, select: merge(p, %{text: p.title})
      query = prepare(from(subquery(query), [])) |> elem(0)
      assert "%Ecto.Query.SubqueryTest.Post{id: &0.id(), title: &0.title(), " <>
             "text: &0.title()}" =
             Macro.to_string(query.from.query.select.expr)

      query = from p in Post, select: merge(%{}, %{})
      query = prepare(from(subquery(query), [])) |> elem(0)
      assert "%{}" = Macro.to_string(query.from.query.select.expr)

      assert_raise Ecto.SubQueryError, ~r/cannot merge because the left side is a map/, fn ->
        query = from p in Post, select: merge(%{}, p)
        prepare(from(subquery(query), []))
      end

      assert_raise Ecto.SubQueryError, ~r/cannot merge because the left side is a Ecto.Query/, fn ->
        query = from p in Post, join: c in Comment, select: merge(p, c)
        prepare(from(subquery(query), []))
      end
    end

    test "requires atom keys for maps" do
      query = from p in Post, select: %{p.id => p.title}
      assert_raise Ecto.SubQueryError, ~r/only atom keys are allowed/, fn ->
        prepare(from(subquery(query), []))
      end
    end

    test "raises on custom expressions" do
      query = from p in Post, select: fragment("? + ?", p.id, p.id)
      assert_raise Ecto.SubQueryError, ~r/subquery must select a source \(t\), a field \(t\.field\) or a map/, fn ->
        prepare(from(subquery(query), []))
      end
    end
  end

  test "prepare: allows type casting from subquery types" do
    query = subquery(from p in Post, join: c in assoc(p, :comments),
                                     select: %{id: p.id, title: p.title})

    permalink = "1-hello-world"
    {_query, params, _key} = prepare(query |> where([p], p.id == ^permalink))
    assert params == [1]

    assert_raise Ecto.Query.CastError, ~r/value `1` in `where` cannot be cast to type :string in query/, fn ->
      prepare(query |> where([p], p.title == ^1))
    end

    assert_raise Ecto.QueryError, ~r/field `unknown` does not exist in subquery in query/, fn ->
      prepare(query |> where([p], p.unknown == ^1))
    end
  end

  test "prepare: wraps subquery errors" do
    exception = assert_raise Ecto.SubQueryError, fn ->
      query = Post |> where([p], p.title == ^1)
      prepare(from(subquery(query), []))
    end

    assert %Ecto.Query.CastError{} = exception.exception
    assert Exception.message(exception) =~ "the following exception happened when compiling a subquery."
    assert Exception.message(exception) =~ "value `1` in `where` cannot be cast to type :string"
    assert Exception.message(exception) =~ "where: p.title == ^1"
    assert Exception.message(exception) =~ "from p in subquery(from p in Ecto.Query.SubqueryTest.Post"
  end

  test "normalize: subqueries" do
    assert_raise Ecto.SubQueryError, ~r/does not allow `update` expressions in query/, fn ->
      query = from p in Post, update: [set: [title: nil]]
      normalize(from(subquery(query), []))
    end

    assert_raise Ecto.QueryError, ~r/`update_all` does not allow subqueries in `from`/, fn ->
      query = from p in Post
      normalize(from(subquery(query), update: [set: [title: nil]]), :update_all)
    end
  end

  test "normalize: subqueries with params in from" do
    query = from p in Post,
              where: [title: ^"hello"],
              order_by: [asc: p.text == ^"world"]

    query = from p in subquery(query),
              where: p.text == ^"last",
              select: [p.title, ^"first"]

    {query, params} = normalize_with_params(query)
    assert [_, {:^, _, [0]}] = query.select.expr
    assert [%{expr: {:==, [], [_, {:^, [], [1]}]}}] = query.from.query.wheres
    assert [%{expr: [asc: {:==, [], [_, {:^, [], [2]}]}]}] = query.from.query.order_bys
    assert [%{expr: {:==, [], [_, {:^, [], [3]}]}}] = query.wheres
    assert params == ["first", "hello", "world", "last"]
  end

  test "normalize: subqueries with params in join" do
    query = from p in Post,
              where: [title: ^"hello"],
              order_by: [asc: p.text == ^"world"]

    query = from c in Comment,
              join: p in subquery(query),
              on: p.text == ^"last",
              select: [p.title, ^"first"]

    {query, params} = normalize_with_params(query)
    assert [_, {:^, _, [0]}] = query.select.expr
    assert [%{expr: {:==, [], [_, {:^, [], [1]}]}}] = hd(query.joins).source.query.wheres
    assert [%{expr: [asc: {:==, [], [_, {:^, [], [2]}]}]}] = hd(query.joins).source.query.order_bys
    assert {:==, [], [_, {:^, [], [3]}]} = hd(query.joins).on.expr
    assert params == ["first", "hello", "world", "last"]
  end

  test "normalize: merges subqueries fields when requested" do
    subquery = from p in Post, select: %{id: p.id, title: p.title}
    query = normalize(from(subquery(subquery), []))
    assert query.select.fields == select_fields([:id, :title], 0)

    query = normalize(from(p in subquery(subquery), select: p.title))
    assert query.select.fields == [{{:., [], [{:&, [], [0]}, :title]}, [], []}]

    query = normalize(from(c in Comment, join: p in subquery(subquery), select: p))
    assert query.select.fields == select_fields([:id, :title], 1)

    query = normalize(from(c in Comment, join: p in subquery(subquery), select: p.title))
    assert query.select.fields == [{{:., [], [{:&, [], [1]}, :title]}, [], []}]

    subquery = from p in Post, select: %{id: p.id, title: p.title}
    assert_raise Ecto.QueryError, ~r/it is not possible to return a map\/struct subset of a subquery/, fn ->
      normalize(from(p in subquery(subquery), select: [:title]))
    end
  end
end
