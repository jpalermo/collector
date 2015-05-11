# encoding: UTF-8
# Copyright (c) 2009-2011 VMware, Inc.
require "spec_helper"
require "vcap/spec/em"
require "em-http/version"
require "webmock"
require "json"

describe VCAP::Component, unix_only: true do
  include VCAP::Spec::EM

  before :each do
    WebMock.allow_net_connect!
  end

  let(:nats) do
    NATS.connect(:uri => "nats://localhost:4223", :autostart => true)
  end

  let(:default_options) { {:type => "type", :nats => nats} }

  after :all do
    if File.exists? NATS::AUTOSTART_PID_FILE
      pid = File.read(NATS::AUTOSTART_PID_FILE).chomp.to_i
      `kill -9 #{pid}`
      FileUtils.rm_f NATS::AUTOSTART_PID_FILE
    end
  end

  it "should publish an announcement" do
    em(:timeout => 2) do
      nats.subscribe("vcap.component.announce") do |msg|
        body = MultiJson.load(msg, :symbolize_keys => true)
        body[:type].should == "type"
        done
      end

      VCAP::Component.register(default_options)
    end
  end

  it "should listen for discovery messages" do
    em(timeout: 2.0) do
      VCAP::Component.register(default_options)

      nats.request("vcap.component.discover") do |msg|
        body = MultiJson.load(msg, :symbolize_keys => true)
        body[:type].should == "type"
        done
      end
    end
  end

  it "should allow you to set an index" do
    em(timeout: 2.0) do
      options = default_options
      options[:index] = 5

      VCAP::Component.register(options)

      nats.request("vcap.component.discover") do |msg|
        body = MultiJson.load(msg, :symbolize_keys => true)
        body[:type].should == "type"
        body[:index].should == 5
        body[:uuid].should =~ /^5-.*/
        done
      end
    end
  end

  describe 'process information' do
    before do
      VCAP::Component.instance_eval do
        remove_instance_variable(:@last_varz_update) if instance_variable_defined?(:@last_varz_update)
      end

      em do
        VCAP::Component.register(:nats => nats)
        done
      end
    end

    it 'includes memory information' do
      Vmstat.stub_chain(:memory, :active_bytes).and_return 75
      Vmstat.stub_chain(:memory, :wired_bytes).and_return 25
      Vmstat.stub_chain(:memory, :inactive_bytes).and_return 660
      Vmstat.stub_chain(:memory, :free_bytes).and_return 340

      VCAP::Component.updated_varz[:mem_used_bytes].should == 100
      VCAP::Component.updated_varz[:mem_free_bytes].should == 1000
    end

    it 'includes CPU information' do
      Vmstat.stub_chain(:load_average, :one_minute).and_return 2.0

      VCAP::Component.updated_varz[:cpu_load_avg].should == 2.0
    end
  end

  it 'does not allow publishing of :config' do
    em do
      options = {:type => 'suppress_test', :nats => nats}
      options[:config] = "fake config"
      expect { VCAP::Component.register(options) }.to raise_error(ArgumentError, /config/i)
      done
    end
    VCAP::Component.varz.should_not have_key(:config)
  end

  describe "http endpoint" do
    let(:host) { VCAP::Component.varz[:host] }
    let(:authorization) { {:head => {"authorization" => VCAP::Component.varz[:credentials]}} }

    it "should let you specify the port" do
      em do
        port = 18123
        options = default_options.merge(:port => port)

        VCAP::Component.register(options)
        VCAP::Component.varz[:host].split(':').last.to_i.should == port

        request = make_em_httprequest(:get, host, "/varz", authorization)
        request.callback do
          request.response_header.status.should == 200
          done
        end
      end
    end

    it "should not truncate varz on second request" do
      em(:timeout => 2) do
        options = default_options

        VCAP::Component.register(options)

        request = make_em_httprequest(:get, host, "/varz", authorization)
        request.callback do
          request.response_header.status.should == 200
          content_length = request.response_header['CONTENT_LENGTH'].to_i
          valid_json?(request.response).should == true

          VCAP::Component.varz[:var] = '♳♴♵♶♷'
          VCAP::Component.varz[:var].length.should_not == VCAP::Component.varz[:var].bytesize

          request2 = make_em_httprequest(:get, host, "/varz", authorization)
          request2.callback do
            request2.response_header.status.should == 200
            content_length2 = request2.response_header['CONTENT_LENGTH'].to_i
            content_length2.should == request2.response.length
            content_length2.should >= content_length + VCAP::Component.varz[:var].length
            valid_json?(request2.response).should == true
            done
          end
        end
      end
    end

    it "should not truncate healthz on second request" do
      em do
        options = default_options

        VCAP::Component.register(options)

        request = make_em_httprequest(:get, host, "/healthz", authorization)
        request.callback do
          request.response_header.status.should == 200

          VCAP::Component.healthz = "∑:healthz†"

          request2 = make_em_httprequest(:get, host, "/healthz", authorization)
          request2.callback do
            request2.response_header.status.should == 200
            content_length2 = request2.response_header['CONTENT_LENGTH'].to_i
            content_length2.should == request2.response.length
            content_length2.should == "∑:healthz†".bytesize
            request2.response.force_encoding("utf-8").should == '∑:healthz†'
            done
          end
        end
      end
    end

    it "should let you specify the auth" do
      em do
        options = default_options
        options[:user] = "foo"
        options[:password] = "bar"

        VCAP::Component.register(options)

        VCAP::Component.varz[:credentials].should == ["foo", "bar"]

        request = make_em_httprequest(:get, host, "/varz", authorization)
        request.callback do
          request.response_header.status.should == 200
          done
        end
      end
    end

    it "should return 401 on unauthorized requests" do
      em do
        VCAP::Component.register(default_options)

        request = make_em_httprequest(:get, host, "/varz")
        request.callback do
          request.response_header.status.should == 401
          done
        end
      end
    end

    it "should return 400 on malformed authorization header" do
      em do
        VCAP::Component.register(default_options)

        request = make_em_httprequest(:get, host, "/varz", :head => {"authorization" => "foo"})
        request.callback do
          request.response_header.status.should == 400
          done
        end
      end
    end
  end

  def make_em_httprequest(method, host, path, opts={})
    ::EM::HttpRequest.new("http://#{host}#{path}").send(method, opts)
  end

  def valid_json?(body)
    JSON.parse(body)
    return true
  rescue JSON::ParserError => pe
    return false
  end
end
