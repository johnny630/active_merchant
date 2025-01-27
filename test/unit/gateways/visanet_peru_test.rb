require 'test_helper'
require 'timecop'

class VisanetPeruTest < Test::Unit::TestCase
  include CommStub

  def setup
    @gateway = VisanetPeruGateway.new(fixtures(:visanet_peru))

    @amount = 100
    @credit_card = credit_card('4500340090000016', verification_value: '377')
    @declined_card = credit_card('4111111111111111')

    @options = {
      billing_address: address,
      order_id: generate_unique_id,
      email: 'visanetperutest@mailinator.com'
    }
  end

  def test_successful_purchase
    @gateway.expects(:ssl_request).with(:post, any_parameters).returns(successful_authorize_response)
    @gateway.expects(:ssl_request).with(:put, any_parameters).returns(successful_capture_response)

    response = @gateway.purchase(@amount, @credit_card, @options)
    assert_success response
    assert_equal 'OK', response.message

    assert_match %r([0-9]{9}|$), response.authorization
    assert_equal 'de9dc65c094fb4f1defddc562731af81', response.params['externalTransactionId']
    assert response.test?
  end

  def test_failed_purchase
    @gateway.expects(:ssl_request).with(:post, any_parameters).returns(failed_authorize_response_bad_card)

    response = @gateway.purchase(@amount, @declined_card, @options)
    assert_failure response
    assert_equal 400, response.error_code
    assert_equal 'Operacion Denegada.', response.message
  end

  def test_nonconsecutive_purchase_numbers
    purchase_times = []

    Timecop.freeze do
      stub_comms(@gateway, :ssl_request) do
        @gateway.authorize(@amount, @credit_card, @options)
      end.check_request do |_method, _endpoint, data, _headers|
        purchase_times << JSON.parse(data)['purchaseNumber'].to_i
      end.respond_with(successful_authorize_response)

      stub_comms(@gateway, :ssl_request) do
        @gateway.authorize(@amount, @credit_card, @options)
      end.check_request do |_method, _endpoint, data, _headers|
        purchase_times << JSON.parse(data)['purchaseNumber'].to_i
      end.respond_with(successful_authorize_response)

      stub_comms(@gateway, :ssl_request) do
        @gateway.authorize(@amount, @credit_card, @options)
      end.check_request do |_method, _endpoint, data, _headers|
        purchase_times << JSON.parse(data)['purchaseNumber'].to_i
      end.respond_with(successful_authorize_response)

      stub_comms(@gateway, :ssl_request) do
        @gateway.authorize(@amount, @credit_card, @options)
      end.check_request do |_method, _endpoint, data, _headers|
        purchase_times << JSON.parse(data)['purchaseNumber'].to_i
      end.respond_with(successful_authorize_response)
    end

    purchase_times.each do |t|
      assert_equal(t.to_s.length, 12)
    end
    assert_equal(purchase_times.uniq.size, purchase_times.size)
  end

  def test_successful_authorize
    @gateway.expects(:ssl_request).returns(successful_authorize_response)
    response = @gateway.authorize(@amount, @credit_card, @options)
    assert_success response
    assert_equal 'OK', response.message
    assert_match %r(^[0-9]{9}|$), response.authorization
    assert_equal @options[:order_id], response.params['externalTransactionId']
    assert_equal '1.00', response.params['data']['IMP_AUTORIZADO']
    assert response.test?
  end

  def test_failed_authorize
    @gateway.expects(:ssl_request).returns(failed_authorize_response_bad_card)
    response = @gateway.authorize(@amount, @declined_card, @options)
    assert_failure response
    assert_equal 400, response.error_code
    assert_equal 'Operacion Denegada.', response.message

    @gateway.expects(:ssl_request).returns(failed_authorize_response_bad_email)
    @options[:email] = 'cybersource@reject.com'
    response = @gateway.authorize(@amount, @credit_card, @options)
    assert_failure response
    assert_equal 400, response.error_code
    assert_equal 'REJECT | Operacion denegada', response.message
  end

  def test_successful_capture
    @gateway.expects(:ssl_request).with(:post, any_parameters).returns(successful_authorize_response)
    @gateway.expects(:ssl_request).with(:put, any_parameters).returns(successful_capture_response)
    response = @gateway.authorize(@amount, @credit_card, @options)
    capture = @gateway.capture(@amount, response.authorization, @options)
    assert_success capture
    assert_equal 'OK', capture.message
    assert_match %r(^[0-9]{9}|$), capture.authorization
    assert_equal 'de9dc65c094fb4f1defddc562731af81', capture.params['externalTransactionId']
    assert capture.test?
  end

  def test_failed_capture
    @gateway.expects(:ssl_request).returns(failed_capture_response)
    invalid_purchase_number = '900000044'
    response = @gateway.capture(@amount, invalid_purchase_number)
    assert_failure response
    assert_equal '[ "NUMORDEN 900000044 no se encuentra registrado", "No se realizo el deposito" ]', response.message
    assert_equal 400, response.error_code
  end

  def test_successful_refund
    @gateway.expects(:ssl_request).returns(successful_authorize_response)
    @gateway.expects(:ssl_request).returns(successful_capture_response)
    response = @gateway.purchase(@amount, @credit_card, @options)
    assert_success response

    @gateway.expects(:ssl_request).with(:put, any_parameters).returns(successful_refund_response)
    refund = @gateway.refund(@amount, response.authorization)
    assert_success refund
    assert_equal 'OK', refund.message
  end

  def test_failed_refund
    @gateway.expects(:ssl_request).with(:put, any_parameters).returns(failed_refund_response)
    response = @gateway.refund(@amount, '122333444')
    assert_failure response
    assert_match(/No se realizo la anulacion del deposito/, response.message)
    assert_equal 400, response.error_code
  end

  def test_failed_full_refund_when_unsettled
    @gateway.expects(:ssl_request).with(:put, any_parameters).returns(failed_refund_response)
    @gateway.expects(:ssl_request).with(:post, any_parameters).returns(failed_refund_with_action_code_response)
    response = @gateway.refund(@amount, '122333444|444333221', force_full_refund_if_unsettled: true)
    assert_failure response
    assert_equal("Operacion Denegada. | [ 'NUMORDEN 122333444 no se encuentra registrado', 'No se realizo la anulacion del deposito' ]", response.message)
    assert_equal 400, response.error_code
  end

  def test_failed_full_refund_when_unsettled_additional_message_concatenation
    @gateway.expects(:ssl_request).with(:put, any_parameters).returns(failed_refund_with_message_and_action_code_response)
    @gateway.expects(:ssl_request).with(:post, any_parameters).returns(failed_refund_with_message_and_action_code_response_2)
    first_msg = 'No se realizo la anulacion del deposito'
    first_dsc = 'Operacion Denegada.'
    second_msg = 'Mal funcionamiento de la inteligencia artificial'
    second_dsc = 'Lo siento Dave, me temo que no puedo hacer eso.'

    response = @gateway.refund(@amount, '122333444|444333221', force_full_refund_if_unsettled: true)
    assert_equal("#{second_msg} | #{second_dsc} | #{first_msg} | #{first_dsc}", response.message)
  end

  def test_successful_void
    @gateway.expects(:ssl_request).returns(successful_authorize_response)
    response = @gateway.authorize(@amount, @credit_card, @options)
    assert_success response

    @gateway.expects(:ssl_request).returns(successful_void_response)
    void = @gateway.void(response.authorization)
    assert_success void
    assert_equal 'OK', void.message
  end

  def test_failed_void
    @gateway.expects(:ssl_request).returns(failed_void_response)
    response = @gateway.void('122333444')
    assert_failure response
    assert_match(/No se ha realizado la anulacion del pedido/, response.message)
    assert_equal 400, response.error_code
  end

  def test_successful_verify
    @gateway.expects(:ssl_request).returns(successful_authorize_response)
    @gateway.expects(:ssl_request).returns(successful_verify_response)
    response = @gateway.verify(@credit_card, @options)
    assert_success response
    assert_equal 'OK', response.message
    assert_equal @options[:order_id], response.params['externalTransactionId']
  end

  def test_failed_verify
    @gateway.expects(:ssl_request).returns(failed_verify_response)
    response = @gateway.verify(@declined_card, @options)
    assert_failure response
    assert_equal 400, response.error_code
    assert_equal 'Operacion Denegada.', response.message
  end

  def test_scrub
    assert @gateway.supports_scrubbing?
    assert_equal @gateway.scrub(pre_scrubbed), post_scrubbed
  end

  private

  def pre_scrubbed
    %q(
      opening connection to devapi.vnforapps.com:443...
      opened
      starting SSL for devapi.vnforapps.com:443...
      SSL established
      <- "POST /api.tokenization/api/v2/merchant/101266802 HTTP/1.1\r\nContent-Type: application/json\r\nAuthorization: Basic QUtJQUpQT1FaN0JBWEpaNUszNUE6VXIrVTBwbjFia2pSaFBHeitHK09MTmpxSWk3T0Jsd2taMmVUSHlTRw==\r\nAccept-Encoding: gzip;q=1.0,deflate;q=0.6,identity;q=0.3\r\nAccept: */*\r\nUser-Agent: Ruby\r\nConnection: close\r\nHost: devapi.vnforapps.com\r\nContent-Length: 551\r\n\r\n"
      <- "{\"amount\":1.0,\"purchaseNumber\":\"858169315\",\"externalTransactionId\":\"858169315\",\"currencyId\":604,\"firstName\":\"Longbob\",\"lastName\":\"Longsen\",\"cardNumber\":\"4500340090000016\",\"cvv2Code\":\"377\",\"expirationYear\":\"2017\",\"expirationMonth\":\"09\",\"email\":\"visanetperutest@mailinator.com\",\"antifraud\":{\"billTo_street1\":\"456 My Street\",\"billTo_city\":\"Ottawa\",\"billTo_state\":\"ON\",\"billTo_country\":\"CA\",\"billTo_postalCode\":\"K1C2N6\",\"deviceFingerprintId\":\"deadbeef\",\"merchantDefineData\":{\"field3\":\"movil\",\"field91\":\"101266802\",\"field92\":\"Cabify\"}},\"createAlias\":false}"
      -> "HTTP/1.1 200 OK\r\n"
      -> "Content-Type: application/json\r\n"
      -> "Date: Mon, 21 Mar 2016 07:21:09 GMT\r\n"
      -> "Server: WildFly/9\r\n"
      -> "X-Powered-By: Undertow/1\r\n"
      -> "Content-Length: 679\r\n"
      -> "Connection: Close\r\n"
      -> "\r\n"
      reading 679 bytes...
      -> "{\"errorCode\":0,\"errorMessage\":\"OK\",\"transactionUUID\":\"3db3c81a-835a-4db6-9e86-eb450c580b2c\",\"externalTransactionId\":\"858169315\",\"transactionDateTime\":1458544860693,\"transactionDuration\":0,\"merchantId\":\"101266802\",\"userTokenId\":null,\"aliasName\":null,\"data\":{\"FECHAYHORA_TX\":\"21/03/2016 02:23\",\"DSC_ECI\":\"Tarjeta no autenticada.\",\"DSC_COD_ACCION\":\"Operacion Autorizada\",\"NOM_EMISOR\":\"FINANCIERA CORDILLER\",\"RESPUESTA\":\"1\",\"ID_UNICO\":\"\",\"NUMORDEN\":\"858169315\",\"CODACCION\":\"000\",\"ETICKET\":\"3106040291071603210220450000\",\"IMP_AUTORIZADO\":\"1.00\",\"DECISIONCS\":\"1\",\"COD_AUTORIZA\":\"160351\",\"CODTIENDA\":\"101266802\",\"PAN\":\"450034******0016\",\"reviewTransaction\":\"false\",\"ORI_TARJETA\":\"N\"}}"
      read 679 bytes
      Conn close
      opening connection to devapi.vnforapps.com:443...
      opened
      starting SSL for devapi.vnforapps.com:443...
      SSL established
      <- "PUT /api.tokenization/api/v2/merchant/101266802/deposit/858169315 HTTP/1.1\r\nAuthorization: Basic QUtJQUpQT1FaN0JBWEpaNUszNUE6VXIrVTBwbjFia2pSaFBHeitHK09MTmpxSWk3T0Jsd2taMmVUSHlTRw==\r\nContent-Type: application/json\r\nAccept-Encoding: gzip;q=1.0,deflate;q=0.6,identity;q=0.3\r\nAccept: */*\r\nUser-Agent: Ruby\r\nConnection: close\r\nHost: devapi.vnforapps.com\r\nContent-Length: 37\r\n\r\n"
      <- "{\"externalTransactionId\":\"858169315\"}"
      -> "HTTP/1.1 200 OK\r\n"
      -> "Content-Type: application/json\r\n"
      -> "Date: Mon, 21 Mar 2016 07:21:36 GMT\r\n"
      -> "Server: WildFly/9\r\n"
      -> "X-Powered-By: Undertow/1\r\n"
      -> "Content-Length: 550\r\n"
      -> "Connection: Close\r\n"
      -> "\r\n"
      reading 550 bytes...
      -> "{\"errorCode\":0,\"errorMessage\":\"OK\",\"transactionUUID\":\"6dee4901-813a-40ab-b571-60ee450be2ea\",\"externalTransactionId\":\"858169315\",\"transactionDateTime\":1458544871523,\"transactionDuration\":0,\"merchantId\":\"101266802\",\"userTokenId\":null,\"aliasName\":null,\"data\":{\"FECHAYHORA_TX\":null,\"DSC_ECI\":null,\"DSC_COD_ACCION\":null,\"NOM_EMISOR\":null,\"ESTADO\":\"Depositado\",\"RESPUESTA\":\"1\",\"ID_UNICO\":null,\"NUMORDEN\":null,\"CODACCION\":null,\"ETICKET\":null,\"IMP_AUTORIZADO\":null,\"DECISIONCS\":null,\"COD_AUTORIZA\":null,\"CODTIENDA\":\"101266802\",\"PAN\":null,\"ORI_TARJETA\":null}}"
      read 550 bytes
      Conn close
    )
  end

  def post_scrubbed
    %q(
      opening connection to devapi.vnforapps.com:443...
      opened
      starting SSL for devapi.vnforapps.com:443...
      SSL established
      <- "POST /api.tokenization/api/v2/merchant/101266802 HTTP/1.1\r\nContent-Type: application/json\r\nAuthorization: Basic [FILTERED]==\r\nAccept-Encoding: gzip;q=1.0,deflate;q=0.6,identity;q=0.3\r\nAccept: */*\r\nUser-Agent: Ruby\r\nConnection: close\r\nHost: devapi.vnforapps.com\r\nContent-Length: 551\r\n\r\n"
      <- "{\"amount\":1.0,\"purchaseNumber\":\"858169315\",\"externalTransactionId\":\"858169315\",\"currencyId\":604,\"firstName\":\"Longbob\",\"lastName\":\"Longsen\",\"cardNumber\":\"[FILTERED]\",\"cvv2Code\":\"[FILTERED]\",\"expirationYear\":\"2017\",\"expirationMonth\":\"09\",\"email\":\"visanetperutest@mailinator.com\",\"antifraud\":{\"billTo_street1\":\"456 My Street\",\"billTo_city\":\"Ottawa\",\"billTo_state\":\"ON\",\"billTo_country\":\"CA\",\"billTo_postalCode\":\"K1C2N6\",\"deviceFingerprintId\":\"deadbeef\",\"merchantDefineData\":{\"field3\":\"movil\",\"field91\":\"101266802\",\"field92\":\"Cabify\"}},\"createAlias\":false}"
      -> "HTTP/1.1 200 OK\r\n"
      -> "Content-Type: application/json\r\n"
      -> "Date: Mon, 21 Mar 2016 07:21:09 GMT\r\n"
      -> "Server: WildFly/9\r\n"
      -> "X-Powered-By: Undertow/1\r\n"
      -> "Content-Length: 679\r\n"
      -> "Connection: Close\r\n"
      -> "\r\n"
      reading 679 bytes...
      -> "{\"errorCode\":0,\"errorMessage\":\"OK\",\"transactionUUID\":\"3db3c81a-835a-4db6-9e86-eb450c580b2c\",\"externalTransactionId\":\"858169315\",\"transactionDateTime\":1458544860693,\"transactionDuration\":0,\"merchantId\":\"101266802\",\"userTokenId\":null,\"aliasName\":null,\"data\":{\"FECHAYHORA_TX\":\"21/03/2016 02:23\",\"DSC_ECI\":\"Tarjeta no autenticada.\",\"DSC_COD_ACCION\":\"Operacion Autorizada\",\"NOM_EMISOR\":\"FINANCIERA CORDILLER\",\"RESPUESTA\":\"1\",\"ID_UNICO\":\"\",\"NUMORDEN\":\"858169315\",\"CODACCION\":\"000\",\"ETICKET\":\"3106040291071603210220450000\",\"IMP_AUTORIZADO\":\"1.00\",\"DECISIONCS\":\"1\",\"COD_AUTORIZA\":\"160351\",\"CODTIENDA\":\"101266802\",\"PAN\":\"450034******0016\",\"reviewTransaction\":\"false\",\"ORI_TARJETA\":\"N\"}}"
      read 679 bytes
      Conn close
      opening connection to devapi.vnforapps.com:443...
      opened
      starting SSL for devapi.vnforapps.com:443...
      SSL established
      <- "PUT /api.tokenization/api/v2/merchant/101266802/deposit/858169315 HTTP/1.1\r\nAuthorization: Basic [FILTERED]==\r\nContent-Type: application/json\r\nAccept-Encoding: gzip;q=1.0,deflate;q=0.6,identity;q=0.3\r\nAccept: */*\r\nUser-Agent: Ruby\r\nConnection: close\r\nHost: devapi.vnforapps.com\r\nContent-Length: 37\r\n\r\n"
      <- "{\"externalTransactionId\":\"858169315\"}"
      -> "HTTP/1.1 200 OK\r\n"
      -> "Content-Type: application/json\r\n"
      -> "Date: Mon, 21 Mar 2016 07:21:36 GMT\r\n"
      -> "Server: WildFly/9\r\n"
      -> "X-Powered-By: Undertow/1\r\n"
      -> "Content-Length: 550\r\n"
      -> "Connection: Close\r\n"
      -> "\r\n"
      reading 550 bytes...
      -> "{\"errorCode\":0,\"errorMessage\":\"OK\",\"transactionUUID\":\"6dee4901-813a-40ab-b571-60ee450be2ea\",\"externalTransactionId\":\"858169315\",\"transactionDateTime\":1458544871523,\"transactionDuration\":0,\"merchantId\":\"101266802\",\"userTokenId\":null,\"aliasName\":null,\"data\":{\"FECHAYHORA_TX\":null,\"DSC_ECI\":null,\"DSC_COD_ACCION\":null,\"NOM_EMISOR\":null,\"ESTADO\":\"Depositado\",\"RESPUESTA\":\"1\",\"ID_UNICO\":null,\"NUMORDEN\":null,\"CODACCION\":null,\"ETICKET\":null,\"IMP_AUTORIZADO\":null,\"DECISIONCS\":null,\"COD_AUTORIZA\":null,\"CODTIENDA\":\"101266802\",\"PAN\":null,\"ORI_TARJETA\":null}}"
      read 550 bytes
      Conn close
    )
  end

  def successful_authorize_response
    <<-RESPONSE
    {
      "errorCode": 0,
      "errorMessage": "OK",
      "externalTransactionId": "#{@options[:order_id]}",
      "merchantId": "101266802",
      "data": {
        "IMP_AUTORIZADO": "1.00"
      }
    }
    RESPONSE
  end

  def failed_authorize_response_bad_card
    <<-RESPONSE
    {
      "errorCode": 400,
      "errorMessage": "[ ]",
      "data": {
        "DSC_COD_ACCION": "Operacion Denegada."
      }
    }
    RESPONSE
  end

  def failed_authorize_response_bad_email
    %q(
      {
        "errorCode": 400,
        "errorMessage": "REJECT",
        "millis": 513,
        "transactionUUID": "e2f0f73d-2f44-4f05-9e13-dad3bf378c57",
        "transactionDate": 1519932476254,
        "data": {
          "FECHAYHORA_TX": "01\/03\/2018 21:26",
          "RES_CVV2": null,
          "CSIMENSAJE": null,
          "ID_UNICO": null,
          "ETICKET": null,
          "DECISIONCS": "REJECT",
          "CSIPORCENTAJEDESCUENTO": null,
          "NROCUOTA": null,
          "CSIIMPORTECOMERCIO": null,
          "CSICODIGOPROGRAMA": null,
          "DSC_ECI": null,
          "ECI": "00",
          "DSC_COD_ACCION": "Operacion denegada",
          "NOM_EMISOR": null,
          "IMPCUOTAAPROX": null,
          "CSITIPOCOBRO": null,
          "NUMREFERENCIA": null,
          "RESPUESTA": "2",
          "NUMORDEN": "376876217",
          "CODACCION": "670",
          "IMP_AUTORIZADO": "0.00",
          "COD_AUTORIZA": null,
          "CODTIENDA": "vndp",
          "PAN": null,
          "reviewTransaction": "false",
          "ORI_TARJETA": null
        },
        "transactionLog": {

        }
      }
    )
  end

  def successful_capture_response
    '{"errorCode":0,"errorMessage":"OK","transactionUUID":"8517cf68-4820-4224-959b-01c8117385e0","externalTransactionId":"de9dc65c094fb4f1defddc562731af81","transactionDateTime":1519937673906,"transactionDuration":0,"merchantId":"543025501","userTokenId":null,"aliasName":null,"data":{"FECHAYHORA_TX":null,"DSC_ECI":null,"DSC_COD_ACCION":null,"NOM_EMISOR":null,"ESTADO":"Depositado","RESPUESTA":"1","ID_UNICO":null,"NUMORDEN":null,"CODACCION":null,"ETICKET":null,"IMP_AUTORIZADO":null,"DECISIONCS":null,"COD_AUTORIZA":null,"CODTIENDA":"543025501","PAN":null,"ORI_TARJETA":null}}'
  end

  def failed_capture_response
    %q(
    {
      "errorCode":400,"errorMessage":"[ \"NUMORDEN 900000044 no se encuentra registrado\", \"No se realizo el deposito\" ]","millis":513,"transactionUUID":"e2f0f73d-2f44-4f05-9e13-dad3bf378c57","transactionDate":1519932476254,"data":{"FECHAYHORA_TX":null,"DSC_ECI":null,"DSC_COD_ACCION":null,"NOM_EMISOR":null,"ESTADO":"","RESPUESTA":"2","ID_UNICO":null,"NUMORDEN":null,"CODACCION":null,"ETICKET":null,"IMP_AUTORIZADO":null,"DECISIONCS":null,"COD_AUTORIZA":null,"CODTIENDA":"543025501","PAN":null,"ORI_TARJETA":null},"transactionLog":{}
    }
    )
  end

  def successful_verify_response
    <<-RESPONSE
    {
      "errorCode": 0,
      "errorMessage": "OK",
      "externalTransactionId": "#{@options[:order_id]}",
      "merchantId": "101266802",
      "userTokenId": null,
      "aliasName": null,
      "data": {
        "FECHAYHORA_TX": null,
        "DSC_ECI": null,
        "DSC_COD_ACCION": null,
        "NOM_EMISOR": null,
        "ESTADO": "Anulado",
        "RESPUESTA": "1",
        "ID_UNICO": null,
        "NUMORDEN": null,
        "CODACCION": null,
        "ETICKET": null,
        "IMP_AUTORIZADO": null,
        "DECISIONCS": null,
        "COD_AUTORIZA": null,
        "CODTIENDA": "543025501",
        "PAN": null,
        "ORI_TARJETA": null
      }
    }
    RESPONSE
  end

  def failed_verify_response
    <<-RESPONSE
    {
      "errorCode": 400,
      "errorMessage": "[ ]",
      "data": {
        "DSC_COD_ACCION": "Operacion Denegada."
      }
    }
    RESPONSE
  end

  def successful_void_response
    <<-RESPONSE
    {
      "errorCode": 0,
      "errorMessage": "OK",
      "externalTransactionId": "987654321",
      "merchantId": "101266802",
      "userTokenId": null,
      "aliasName": null,
      "data": {
        "FECHAYHORA_TX": null,
        "DSC_ECI": null,
        "DSC_COD_ACCION": null,
        "NOM_EMISOR": null,
        "ESTADO": "Anulado",
        "RESPUESTA": "1",
        "ID_UNICO": null,
        "NUMORDEN": null,
        "CODACCION": null,
        "ETICKET": null,
        "IMP_AUTORIZADO": null,
        "DECISIONCS": null,
        "COD_AUTORIZA": null,
        "CODTIENDA": "543025501",
        "PAN": null,
        "ORI_TARJETA": null
      }
    }
    RESPONSE
  end

  def failed_void_response
    <<-RESPONSE
    {
      "errorCode": 400,
      "errorMessage": "[ 'NUMORDEN no se encuentra registrado.', 'No se ha realizado la anulacion del pedido' ]",
      "data": {
        "FECHAYHORA_TX": null,
        "DSC_ECI": null,
        "DSC_COD_ACCION": null,
        "NOM_EMISOR": null,
        "ESTADO": " ",
        "RESPUESTA": "2",
        "ID_UNICO": null,
        "NUMORDEN": null,
        "CODACCION": null,
        "ETICKET": null,
        "IMP_AUTORIZADO": null,
        "DECISIONCS": null,
        "COD_AUTORIZA": null,
        "CODTIENDA": "543025501",
        "PAN": null,
        "ORI_TARJETA": null
      },
      "transactionLog": {

      }
    }
    RESPONSE
  end

  def successful_refund_response
    <<-RESPONSE
    {
      "errorCode":0,
      "errorMessage":"OK",
      "transactionUUID":"388e1e2b-46cc-4abc-818a-a7e4691bf67a",
      "externalTransactionId":null,
      "transactionDateTime":1463682009508,
      "transactionDuration":0,
      "merchantId":"101266802",
      "userTokenId":null,
      "aliasName":null,
      "data":{"ESTADO":"Autorizado","RESPUESTA":"1"}
    }
    RESPONSE
  end

  def failed_refund_response
    <<-RESPONSE
    {
      "errorCode": 400,
      "errorMessage": "[ 'NUMORDEN 122333444 no se encuentra registrado', 'No se realizo la anulacion del deposito' ]",
      "data": {
        "ESTADO": "",
        "RESPUESTA": "2"
      },
      "transactionLog": {

      }
    }
    RESPONSE
  end

  def failed_refund_with_action_code_response
    <<-RESPONSE
    {
      "errorCode": 400,
      "errorMessage": "[ ]",
      "data": {
        "ESTADO": "",
        "RESPUESTA": "2",
        "DSC_COD_ACCION": "Operacion Denegada."
      },
      "transactionLog": {

      }
    }
    RESPONSE
  end

  def failed_refund_with_message_and_action_code_response
    <<-RESPONSE
    {
      "errorCode": 400,
      "errorMessage": "No se realizo la anulacion del deposito",
      "data": {
        "ESTADO": "",
        "RESPUESTA": "2",
        "DSC_COD_ACCION": "Operacion Denegada."
      },
      "transactionLog": {

      }
    }
    RESPONSE
  end

  def failed_refund_with_message_and_action_code_response_2
    <<-RESPONSE
    {
      "errorCode": 400,
      "errorMessage": "Mal funcionamiento de la inteligencia artificial",
      "data": {
        "ESTADO": "",
        "RESPUESTA": "2",
        "DSC_COD_ACCION": "Lo siento Dave, me temo que no puedo hacer eso."
      },
      "transactionLog": {

      }
    }
    RESPONSE
  end
end
