require 'httparty'
require 'uri'
require "base64"
require 'openssl'

## auth su api
# https://login.microsoftonline.com/97d6a602-2492-4f4c-9585-d2991eb3bf4c/oauth2/token
# L’ambiente di Test su UAT è UAT281: ( DEDA UAT281 - DEMO DEMOGRAFIA 2 – id 348 )
# Application ID:
# aebe50cd-bbc0-4bf5-94ba-4e70590bcf1a
# Secret:
# w9=jyc0bA.sBVLX@aHD:87lPZlS4r=7x

class ApplicationController < ActionController::Base
  include ApplicationHelper
  before_action :get_dominio_sessione_utente, :get_layout_portale
  
  #ROOT della main_app
  def index
    #carico cf in variabile per usarla sulla view
    @cf_utente_loggato = session[:cf]

    render :template => "application/index" , :layout => "layout_portali/#{session[:nome_file_layout]}"

  end
  
  def get_demografici_token  
    params = {
       "targetResource": "https://api.civilianextuat.it/", 
       "tenantId": "#{session[:user]["api_demografici"]["tenant"]}",
       "clientId": "#{session[:user]["api_demografici"]["client_id"]}",
       "secret": "#{session[:user]["api_demografici"]["secret"]}"
    }
    #logger.debug params
    result = HTTParty.post("https://login.microsoftonline.com/#{session[:user]["api_demografici"]["tenant"]}/oauth2/token", 
    :body => params.to_json,
    :headers => { 'Content-Type' => 'application/json','Accept' => 'application/json'  } )

    if !result["result"].nil? && result["result"].length>0
      session[:token] = result["result"]["token"]
    end
    
    render :json => result
  end  

  # richiesta da portale cittadino
  def inserisci_richiesta
    # ricevo dal portale del cittadino una richiesta di certificato
    # il portale deve inviarmi il tenant
    # inserisco in certificati la richiesta ricevuta con stato appropriato 
    # richiesto se !bollo&&!segreteria, da pagare se bollo||segreteria
    # restituisco risultato inserimento e id richiesta
    # se da pagare, poi il portale farà un redirect su pagamenti

    nuovo_certificato = {
      "tenant": params[:tenant],
      "codice_fiscale": params[:codice_fiscale],
      "codice_certificato": params[:codice_certificato], # ottenuti da compilazione form da parte del cittadino, questi verranno ottenuti da ws che restituisce elenco tipi certificato
      "bollo": params[:bollo], # ottenuti da compilazione form da parte del cittadino, sì/no
      "diritti_segreteria": params[:diritti_segreteria], # ottenuti da compilazione form da parte del cittadino, sì/no
      "uso": params[:uso], # ottenuti da compilazione form da parte del cittadino, probabilmente recuperati da ws?
      "richiedente_cf": params[:richiedente_cf],
    }

  end

  # richiesta da portale cittadino
  def aggiorna_richiesta
    # ricevo dal cittadino un aggiornamento di richiesta di certificato
    # ad esempio quando ha pagato un certificato con bollo||segreteria
    # il portale deve inviarmi il tenant

    
  end
  
  def sconosciuto
  end
  
  #da fare
  def error_dati
  end
    
  private

  def get_dominio_sessione_utente
    #permetto di usare tutti i parametri e li converto in hash
    hash_params = params.permit!.to_hash
    if !hash_params['c_id'].blank? && session[:client_id] != hash_params['c_id']
      reset_session
    end
    if session.blank? || session[:user].blank? #controllo se ho fatto login
      #se ho la sessione vuota devo ottenere una sessione dal portale
      #se arriva un client_id (parametro c_id) e id_utente lo uso per richiedere sessione
      if !hash_params['c_id'].blank? && !hash_params['u_id'].blank?

        #ricavo dominio da oauth2
        url_oauth2_get_info = "https://login.soluzionipa.it/oauth/application/get_info_cid/"+hash_params['c_id']
        #url_oauth2_get_info = "http://localhost:3001/oauth/application/get_info_cid/"+hash_params['c_id'] #PER TEST
        result_info_ente = HTTParty.get(url_oauth2_get_info,
          :headers => { 'Content-Type' => 'application/json', 'Accept' => 'application/json' } )
        hash_result_info_ente = result_info_ente.parsed_response
        @dominio = hash_result_info_ente['url_ente']
        #@dominio = "https://civilianext.soluzionipa.it/portal" #per test
        session[:dominio] = @dominio
        #creo jwt per avere sessione utente
        hash_jwt_app = {
          iss: 'demografici.soluzionipa.it', #dominio finale dell'app demografici
          id_app: 'demografici',
          id_utente: hash_params['u_id'],
          sid: hash_params['sid'],
          api_next: true
        }
        jwt = JsonWebToken.encode(hash_jwt_app)
        #richiesta in post a get_login_session con authorization bearer

        result = HTTParty.post(@dominio+"/autenticazione/get_login_session.json", 
          :body => hash_params,
          :headers => { 'Authorization' => 'Bearer '+jwt } )
        hash_result = result.parsed_response
        #se ho risultato con stato ok ricavo dati dal portale e salvo in sessione 
        #impostare durata sessione in application.rb: ora dura 30 minuti
        if !hash_result.blank? && !hash_result["stato"].nil? && hash_result["stato"] == 'ok'
          jwt_data = JsonWebToken.decode(hash_result['token'])
          session[:user] = jwt_data #uso questo oggetto per capire se utente connesso!
          session[:cf] = jwt_data[:cf]
          @nome = jwt_data[:nome] 
          @cognome = jwt_data[:cognome]
          session[:client_id] = hash_params['c_id']
          # TODO gestire meglio il dominio
          solo_dom = @dominio.gsub("/portal","")
          
        else
          #se ho problemi ritorno su portale con parametro di errore
          unless @dominio.blank?
            redirect_to @dominio+"/?err"
            return
          else
            redirect_to sconosciuto_url
            return   
          end
          
        end
      else

        unless @dominio.blank?
          #mando a fare autenticazione sul portal
          redirect_to @dominio+"/autenticazione"
          return
        else
          redirect_to sconosciuto_url
          return    
        end
        
      end

    else
      @dominio = session[:dominio] || "dominio non presente"
    end
  end

  def get_layout_portale
    #ricavo l'hash del layout
    result = HTTParty.get(session[:dominio]+"/get_hash_layout.json", 
      :body => {})
    hash_result = result.parsed_response
    ritornato_hash = false
    if hash_result['esito'] == 'ok'
      ritornato_hash = true
    else
      logger.error "Portale cittadino #{session[:dominio]} non raggiungibile per ottenere hash di layout! Rifaccio chiamata per possibili problemi con Single Thread"
      i = 0
      while ritornato_hash == false && i < 10 
        sleep 1
        result = HTTParty.get(session[:dominio]+"/get_hash_layout.json", 
          :body => {})
        hash_result = result.parsed_response
        if hash_result['esito'] == 'ok'
          ritornato_hash = true
        end
      end
    end  

    if ritornato_hash
        hash_layout = hash_result['hash']
        nome_file = "#{session[:client_id]}_#{hash_layout}.html.erb"
        session[:nome_file_layout] = nome_file
        #cerco if file di layout se presente uso quello
        if Dir["#{Rails.root}/app/views/layouts/layout_portali/#{session[:client_id]}_#{hash_layout}.*"].length == 0
            #scrivo il file
            #cancello i vecchi file con stesso client_id (della stesa installazione)
            Dir["#{Rails.root}/app/views/layouts/layout_portali/#{session[:client_id]}_*"].each{ |vecchio_layout|
              File.delete(vecchio_layout) 
            }
            #richiedo il layout dal portale, questa non dovrebbe avere problemi di single thread in quanto va a prendere html da sessione sul portale
            result = HTTParty.get(session[:dominio]+"/get_html_layout.json", :body => {})
            hash_result = result.parsed_response
            html_layout = Base64.decode64(hash_result['html'])
            #Aggiungo variabile per disabilitare Function.prototype.bind in portal.x.js
            js_da_iniettare = '<script type="text/javascript">window.appType = "external";</script>'
            #Devo iniettare nel layout gli assets e lo yield
            head_da_iniettare = "<%= csrf_meta_tags %>
            <%= csp_meta_tag %>
            <%= stylesheet_link_tag    'application', media: 'all', 'data-turbolinks-track': 'reload' %>"
            html_layout = html_layout.gsub("</head>", head_da_iniettare+"</head>").gsub("id=\"portal_container\">", "id=\"portal_container\"><%=yield%>")
            html_layout = html_layout.sub("<script",js_da_iniettare+" <script")
            #parte che include il js della parte react sul layout CHE VA ALLA FINE, ALTRIMENTI REACT NON VA
            html_layout = html_layout.gsub("</body>","<%= javascript_pack_tag 'app_demografici' %> </body>")
            path_dir_layout = "#{Rails.root}/app/views/layouts/layout_portali/"
            File.open(path_dir_layout+nome_file, "w") { |file| file.puts html_layout.force_encoding(Encoding::UTF_8).encode(Encoding::UTF_8) }
        end
    else
      redirect_to session[:dominio]+"/?err=no_hash"
    
    end
  end


end