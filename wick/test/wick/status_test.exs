defmodule Wick.StatusTest do
  use ExUnit.Case, async: true

  alias Wick.Status

  doctest Status

  describe "to_coap/1" do
    test "maps every recognised status to a {class, detail} pair" do
      for status <- Status.all() do
        assert {class, detail} = Status.to_coap(status)
        assert class in 0..7
        assert detail in 0..31
      end
    end

    test "produces the OMA LwM2M 1.2 standard codes" do
      assert Status.to_coap(:created) == {2, 1}
      assert Status.to_coap(:deleted) == {2, 2}
      assert Status.to_coap(:changed) == {2, 4}
      assert Status.to_coap(:content) == {2, 5}
      assert Status.to_coap(:bad_request) == {4, 0}
      assert Status.to_coap(:unauthorized) == {4, 1}
      assert Status.to_coap(:not_found) == {4, 4}
      assert Status.to_coap(:method_not_allowed) == {4, 5}
      assert Status.to_coap(:not_acceptable) == {4, 6}
      assert Status.to_coap(:request_entity_too_large) == {4, 13}
      assert Status.to_coap(:unsupported_content_format) == {4, 15}
      assert Status.to_coap(:internal_server_error) == {5, 0}
      assert Status.to_coap(:not_implemented) == {5, 1}
      assert Status.to_coap(:service_unavailable) == {5, 3}
    end
  end

  describe "from_coap/1" do
    test "round-trips every recognised status" do
      for status <- Status.all() do
        assert Status.from_coap(Status.to_coap(status)) == status
      end
    end

    test "returns nil for an unrecognised but valid CoAP code" do
      # 2.03 ('Valid', not used by LwM2M)
      assert Status.from_coap({2, 3}) == nil
      # 4.03 ('Forbidden', not used by LwM2M)
      assert Status.from_coap({4, 3}) == nil
    end
  end

  describe "success?/1 and error?/1" do
    test "every 2.xx status is a success" do
      for status <- [:created, :deleted, :changed, :content] do
        assert Status.success?(status)
        refute Status.error?(status)
      end
    end

    test "every 4.xx status is an error" do
      for status <- [
            :bad_request,
            :unauthorized,
            :not_found,
            :method_not_allowed,
            :not_acceptable,
            :request_entity_too_large,
            :unsupported_content_format
          ] do
        refute Status.success?(status)
        assert Status.error?(status)
      end
    end

    test "every 5.xx status is an error" do
      for status <- [:internal_server_error, :not_implemented, :service_unavailable] do
        refute Status.success?(status)
        assert Status.error?(status)
      end
    end
  end

  describe "all/0" do
    test "returns every status atom in alphabetical order" do
      atoms = Status.all()
      assert length(atoms) == 14
      assert atoms == Enum.sort(atoms)
    end
  end
end
