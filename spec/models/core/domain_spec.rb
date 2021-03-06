require "spec_helper"

module VCAP::CloudController
  describe Models::Domain, type: :model do
    let(:domain) { Models::Domain.make }

    it_behaves_like "a CloudController model", {
      :required_attributes          => [:name, :owning_organization, :wildcard],
      :db_required_attributes       => [:name],
      :unique_attributes            => :name,
      :custom_attributes_for_uniqueness_tests =>  -> do
        @owning_organization ||= Models::Organization.make
        { owning_organization: @owning_organization }
      end,
      :stripped_string_attributes   => :name,
      :many_to_zero_or_one => {
        :owning_organization => {
          :delete_ok => true,
          :create_for => lambda { |domain|
            org = Models::Organization.make
            domain.owning_organization = org
            domain.save
            org
          }
        }
      },
      :many_to_many => {
        :organizations => lambda {
          |domain| Models::Organization.make
        }
      },
      :many_to_zero_or_more => {
        :spaces => lambda { |domain|
          Models::Space.make(:organization => domain.owning_organization)
        }
      },
      :one_to_zero_or_more => {
        :routes => {
          :delete_ok => true,
          :create_for => lambda { |domain|
            domain.update(:wildcard => true)
            space = Models::Space.make(:organization => domain.owning_organization)
            space.add_domain(domain)
            Models::Route.make(:domain => domain, :space => space)
          }
        }
      }
    }

    describe "#as_summary_json" do
      context "with a system domain" do
        subject { Models::Domain.new(:name => Sham.domain, :owning_organization => nil) }

        it "returns a hash containing the domain details" do
          subject.as_summary_json.should == {
            :guid => subject.guid,
            :name => subject.name,
            :owning_organization_guid => nil
          }
        end
      end

      context "with a custom domain" do
        let(:organization) { Models::Organization.make }
        subject { Models::Domain.new(:name => Sham.domain, :owning_organization => organization) }

        it "returns a hash containing the domain details" do
          subject.as_summary_json.should == {
            :guid => subject.guid,
            :name => subject.name,
            :owning_organization_guid => subject.owning_organization.guid
          }
        end
      end
    end

    describe "#intermidiate_domains" do
      context "name is nil" do
        it "should return nil" do
          Models::Domain.intermediate_domains(nil).should == nil
        end
      end

      context "name is empty" do
        it "should return nil" do
          Models::Domain.intermediate_domains("").should == nil
        end
      end

      context "name is not a valid domain" do
        Models::Domain.intermediate_domains("bla").should == nil
      end

      context "valid domain" do
        it "should return an array of intermediate domains (minus the tld)" do
          Models::Domain.intermediate_domains("a.b.c.d.com").should ==
            [ "com", "d.com", "c.d.com", "b.c.d.com", "a.b.c.d.com"]
        end
      end
    end

    describe "creating shared domains" do
      context "as an admin" do
        before do
          admin = Models::User.make(:admin => true)
          SecurityContext.set(admin)
        end

        after do
          SecurityContext.clear
        end

        it "should allow the creation of a shared domain" do
          d = Models::Domain.new(:name => "shared.com")
          d.owning_organization.should be_nil
        end
      end

      context "as a standard user" do
        before do
          user = Models::User.make(:admin => false)
          SecurityContext.set(user)
        end

        after do
          SecurityContext.clear
        end

        it "should not allow the creation of a shared domain" do
          expect {
            Models::Domain.create(:name => "shared.com")
          }.to raise_error Sequel::ValidationFailed, /organization presence/
        end
      end
    end

    describe "overlapping domains" do
      shared_examples "overlapping domains" do
        let(:domain_a) { Models::Domain.make(:name => name_a) }

        context "owned by the same org" do
          it "should be allowed" do
            domain_a.should be_valid
            Models::Domain.make(
              :name => name_b,
              :owning_organization => domain_a.owning_organization,
            ).should be_valid
          end
        end

        context "owned by different orgs" do
          it "should not be allowed" do
            domain_a.should be_valid
            expect {
              Models::Domain.make(:name => name_b)
            }.to raise_error(Sequel::ValidationFailed, /overlapping_domain/)
          end
        end
      end

      shared_examples "overlapping with system domain" do
        context "with system domain and non system domain" do

          it "should not be allowed" do
            system_domain = Models::Domain.new(
              :name => name_a,
              :wildcard => true,
              :owning_organization => nil
            ).save(:validate => false)

            expect {
              Models::Domain.make(:name => name_b)
            }.to raise_error(Sequel::ValidationFailed, /overlapping_domain/)
          end
        end
      end

      context "exact overlap" do
        let(:name_a) { Sham.domain }
        let(:name_b) { "foo.#{name_a}" }

        context "owned by different orgs" do
          it "should not be allowed" do
            domain_a = Models::Domain.make(:name => name_a)
            expect {
              Models::Domain.make(:name => domain_a.name)
            }.to raise_error(Sequel::ValidationFailed, /overlapping_domain/)
          end
        end

        include_examples "overlapping with system domain"
      end

      context "one level overlap" do
        let(:name_a) { Sham.domain }
        let(:name_b) { "foo.#{name_a}" }
        include_examples "overlapping domains"
        include_examples "overlapping with system domain"
      end

      context "multi level overlap" do
        let(:name_a) { "foo.bar.#{Sham.domain}" }
        let(:name_b) { "a.b.foo.bar.#{name_a}" }
        include_examples "overlapping domains"
        include_examples "overlapping with system domain"
      end
    end

    context "relationships" do
      context "custom domains" do
        let(:org) { Models::Organization.make }

        let(:domain) {
          Models::Domain.make(:owning_organization => org)
        }

        let(:space) { Models::Space.make }

        it "should not associate with an app space on a different org" do
          expect {
            domain.add_space(space)
          }.to raise_error Models::Domain::InvalidSpaceRelation
        end

        it "should not associate with orgs other than the owning org" do
          expect {
            domain.add_organization(Models::Organization.make)
          }.to raise_error Models::Domain::InvalidOrganizationRelation
        end

        it "should auto-associate with the owning org" do
          domain.should be_valid
          org.domains.should include(domain)
        end
      end

      context "shared domains" do
        let(:shared_domain) do
          Models::Domain.find_or_create_shared_domain(Sham.domain)
        end

        it "should auto-associate with a new org" do
          shared_domain.should be_valid
          org = Models::Organization.make
          org.domains.should include(shared_domain)
        end

        it "should not auto-associate with an existing org" do
          org = Models::Organization.make
          new_shared_domain = Models::Domain.find_or_create_shared_domain(Sham.domain)
          org.domains.should_not include(new_shared_domain)
        end

        it "should manually associate with an org" do
          # while this seems like it shouldn't need to be tested, at some point
          # in the past, this pattern had failed.
          shared_domain.add_organization(Models::Organization.make)
          shared_domain.should be_valid
          shared_domain.save
          shared_domain.should be_valid
        end
      end
    end

    describe "validations" do
      describe "name" do
        it "should accept a two level domain" do
          domain.name = "a.com"
          domain.should be_valid
        end

        it "should accept a three level domain" do
          domain.name = "a.b.com"
          domain.should be_valid
        end

        it "should accept a four level domain" do
          domain.name = "a.b.c.com"
          domain.should be_valid
        end

        it "should accept a domain with a 2 char top level domain" do
          domain.name = "b.c.au"
          domain.should be_valid
        end

        it "should not allow a one level domain" do
          domain.name = "com"
          domain.should_not be_valid
        end

        it "should not allow a domain without a host" do
          domain.name = ".com"
          domain.should_not be_valid
        end

        it "should not allow a domain with a trailing dot" do
          domain.name = "a.com."
          domain.should_not be_valid
        end

        it "should not allow a domain with a leading dot" do
          domain.name = ".b.c.com"
          domain.should_not be_valid
        end

        it "should not allow a domain with a single char top level domain" do
          domain.name = "b.c.d"
          domain.should_not be_valid
        end

        it "should not allow a domain with a 6 char top level domain" do
          domain.name = "b.c.abcefg"
          domain.should_not be_valid
        end

        it "should perform case insensitive uniqueness" do
          d = Models::Domain.new(
            :owning_organization => domain.owning_organization,
            :name => domain.name.upcase)
            d.should_not be_valid
        end

        it "should not remove the wildcard flag if routes are using it" do
          d = Models::Domain.make(:wildcard => true)
          s = Models::Space.make(:organization => d.owning_organization)
          s.add_domain(d)
          r = Models::Route.make(:host => Sham.host, :domain => d, :space => s)
          expect {
            d.update(:wildcard => false)
          }.to raise_error(Sequel::ValidationFailed)
        end

        it "should remove the wildcard flag if no routes are using it" do
          d = Models::Domain.make(:wildcard => true)
          s = Models::Space.make(:organization => d.owning_organization)
          s.add_domain(d)
          r = Models::Route.make(:host => "", :domain => d, :space => s)
          d.update(:wildcard => false)
        end
      end
    end

    describe "default_serving_domain" do
      context "with the default serving domain name set" do
        before do
          Models::Domain.default_serving_domain_name = "foo.com"
        end

        after do
          Models::Domain.default_serving_domain_name = nil
        end

        it "should return the default serving domain" do
          d = Models::Domain.default_serving_domain
          d.name.should == "foo.com"
        end
      end

      context "without the default seving domain name set" do
        it "should return nil" do
          d = Models::Domain.default_serving_domain
          d.should be_nil
        end
      end
    end

    context "shared_domains" do
      before do
        reset_database
      end

      context "with no domains" do
        it "should be empty" do
          Models::Domain.shared_domains.count.should == 0
        end
      end

      context "with a shared domain and a owned domain" do
        it "should return the shared domain" do
          shared = Models::Domain.find_or_create_shared_domain("a.com")
          Models::Domain.make
          Models::Domain.shared_domains.all.should == [shared]
        end
      end
    end

    describe "#destroy" do
      subject { domain.destroy }
      let(:space) do
        Models::Space.make(:organization => domain.owning_organization).tap do |space|
          space.add_domain(domain)
          space.save
        end
      end

      it "should destroy the routes" do
        route = Models::Route.make(:domain => domain, :space => space)
        expect { subject }.to change { Models::Route.where(:id => route.id).count }.by(-1)
      end

      it "nullifies the organization" do
        organization = domain.owning_organization
        expect { subject }.to change { organization.reload.domains.count }.by(-1)
      end

      it "nullifies the space" do
        expect { subject }.to change { space.reload.domains.count }.by(-1)
      end
    end
  end
end
