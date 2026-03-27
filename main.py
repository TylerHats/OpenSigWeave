import os
import json
import httpx
import re
from fastapi import FastAPI, Depends, HTTPException, Request, Header
from fastapi.responses import RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from sqlalchemy import create_engine, Column, Integer, String, Boolean, ForeignKey, Text
from sqlalchemy.orm import declarative_base, sessionmaker, Session
from pydantic import BaseModel
from typing import List, Optional

from dotenv import load_dotenv
from starlette.middleware.sessions import SessionMiddleware
from authlib.integrations.starlette_client import OAuth

load_dotenv()

# 2. Database Setup
SQLALCHEMY_DATABASE_URL = "sqlite:///./opensigweave.db"
engine = create_engine(SQLALCHEMY_DATABASE_URL, connect_args={"check_same_thread": False})
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()

class DomainDB(Base):
    __tablename__ = "domains"
    id = Column(Integer, primary_key=True, index=True)
    domain_name = Column(String, unique=True, index=True)
    is_active = Column(Boolean, default=True)
    allow_overrides = Column(Boolean, default=True)
    inject_on_replies = Column(Boolean, default=False)
    trim_whitespace = Column(Boolean, default=True)
    strip_device_signatures = Column(Boolean, default=False)
    template_html = Column(Text, default="<p>Best Regards,</p><p><br></p><p><strong>{{ first_name }} {{ last_name }}</strong></p><p>{{ title }} | {{ domain_name }}</p>")

class UserOverrideDB(Base):
    __tablename__ = "user_overrides"
    id = Column(Integer, primary_key=True, index=True)
    user_email = Column(String, unique=True, index=True)
    html_content = Column(Text, default="")
    is_disabled = Column(Boolean, default=False)

Base.metadata.create_all(bind=engine)

# Pydantic Models
class DomainCreate(BaseModel):
    domain_name: str
    is_active: bool = True

class DomainUpdate(BaseModel):
    is_active: bool
    allow_overrides: bool
    inject_on_replies: bool
    trim_whitespace: bool
    strip_device_signatures: bool
    template_html: str

class OverrideUpdate(BaseModel):
    html_content: str

class AdminOverrideSave(BaseModel):
    user_email: str
    html_content: str
    is_disabled: bool = False

# 3. FastAPI App Initialization
app = FastAPI(title="OpenSigWeave API", version="1.0.0", docs_url=None, redoc_url=None, openapi_url=None)
app.add_middleware(SessionMiddleware, secret_key=os.environ.get("SECRET_KEY", "fallback-secret"))

oauth = OAuth()
oauth.register(
    name='authentik',
    server_metadata_url=f"{os.environ.get('AUTHENTIK_URL')}/application/o/{os.environ.get('AUTHENTIK_SLUG')}/.well-known/openid-configuration",
    client_id=os.environ.get('CLIENT_ID'),
    client_secret=os.environ.get('CLIENT_SECRET'),
    client_kwargs={'scope': 'openid email profile attributes'}
)

templates = Jinja2Templates(directory="templates")
app.mount("/branding", StaticFiles(directory="branding"), name="branding")
app.mount("/static", StaticFiles(directory="static"), name="static")

def get_db():
    db = SessionLocal()
    try: yield db
    finally: db.close()

def is_admin_user(request: Request):
    user = request.session.get('user')
    if not user: return False
    return 'signature-admins' in user.get('groups', [])

# --- Web UI Routes ---
@app.get("/login")
async def login(request: Request):
    redirect_uri = request.url_for('auth').replace(scheme='https')
    return await oauth.authentik.authorize_redirect(request, str(redirect_uri))

@app.get("/auth")
async def auth(request: Request):
    try:
        token = await oauth.authentik.authorize_access_token(request)
        user = token.get('userinfo')
        if user: request.session['user'] = user
    except Exception as e:
        print(f"Login failed: {e}")
    return RedirectResponse(url='/')

@app.get("/logout")
async def logout(request: Request):
    request.session.pop('user', None)
    authentik_url = os.environ.get('AUTHENTIK_URL')
    slug = os.environ.get('AUTHENTIK_SLUG')
    return_url = str(request.url_for('read_root')).replace('http://', 'https://')
    return RedirectResponse(url=f"{authentik_url}/application/o/{slug}/end-session/?post_logout_redirect_uri={return_url}")

@app.get("/")
def read_root(request: Request, db: Session = Depends(get_db)):
    user = request.session.get('user')
    if not user: return RedirectResponse(url='/login')
        
    user_groups = user.get('groups', [])
    is_admin = 'signature-admins' in user_groups
    is_user = 'signature-users' in user_groups
    if not is_admin and not is_user:
        return templates.TemplateResponse("error.html", {"request": request, "message": "You do not have permission to access the Signature Portal."})

    has_logo = os.path.isfile("branding/logo.png")
    has_favicon = os.path.isfile("branding/favicon.ico")
    
    app_name = "OpenSigWeave"
    app_color = "#60a5fa"
    
    settings_path = "branding/settings.json"
    if os.path.isfile(settings_path):
        try:
            with open(settings_path, "r") as f:
                settings = json.load(f)
                if "app_name" in settings: app_name = settings["app_name"]
                if "app_color" in settings: app_color = settings["app_color"]
        except Exception: pass
            
    attributes = user.get('attributes', {}) if user else {}
    phone = attributes.get('phone', 'Not Set')
    title = attributes.get('title', 'Not Set')

    name = user.get('name', '')
    name_parts = name.split(' ')
    first_name = name_parts[0] if name_parts else ''
    last_name = ' '.join(name_parts[1:]) if len(name_parts) > 1 else ''
    email = user.get('email', '')
    
    domain_part = email.split('@')[-1] if '@' in email else ''
    domain_obj = db.query(DomainDB).filter(DomainDB.domain_name == domain_part).first()
    override_obj = db.query(UserOverrideDB).filter(UserOverrideDB.user_email == email).first()
    
    can_edit = False
    lock_reason = "Your email domain is not registered in this system."
    
    if override_obj and override_obj.is_disabled:
        lock_reason = "Your signature has been explicitly disabled by an administrator."
    elif domain_obj:
        if not domain_obj.is_active:
            lock_reason = "Signatures for your domain are currently disabled by the administrator."
        elif not domain_obj.allow_overrides:
            lock_reason = "Custom overrides have been disabled for your domain. The master template will be used."
        else:
            can_edit = True
            lock_reason = ""
    
    raw_template = domain_obj.template_html if domain_obj else "<p class='text-red-500'>No active domain template found for your email domain.</p>"
    
    parsed_template = raw_template.replace("{{ first_name }}", first_name).replace("{{ last_name }}", last_name).replace("{{ title }}", title).replace("{{ phone }}", phone).replace("{{ email }}", email).replace("{{ domain_name }}", domain_part)

    return templates.TemplateResponse("index.html", {
        "request": request, "has_logo": has_logo, "has_favicon": has_favicon, "app_name": app_name, "app_color": app_color,
        "user": user, "is_admin": is_admin, "authentik_settings_url": f"{os.environ.get('AUTHENTIK_URL', '')}/if/user/#/settings",
        "phone": phone, "title": title, "first_name": first_name, "last_name": last_name,
        "domain_template": parsed_template, "can_edit": can_edit, "lock_reason": lock_reason
    })

# --- API Endpoints ---
@app.get("/domains/")
def read_domains(db: Session = Depends(get_db)):
    return db.query(DomainDB).all()

@app.post("/domains/")
def create_domain(domain: DomainCreate, db: Session = Depends(get_db)):
    db_domain = DomainDB(domain_name=domain.domain_name, is_active=domain.is_active)
    db.add(db_domain)
    db.commit()
    db.refresh(db_domain)
    return db_domain

@app.put("/domains/{domain_id}")
def update_domain(domain_id: int, domain_update: DomainUpdate, db: Session = Depends(get_db)):
    db_domain = db.query(DomainDB).filter(DomainDB.id == domain_id).first()
    if not db_domain: raise HTTPException(status_code=404)
    db_domain.is_active = domain_update.is_active
    db_domain.allow_overrides = domain_update.allow_overrides
    db_domain.inject_on_replies = domain_update.inject_on_replies
    db_domain.trim_whitespace = domain_update.trim_whitespace
    db_domain.strip_device_signatures = domain_update.strip_device_signatures
    db_domain.template_html = domain_update.template_html
    db.commit()
    return {"status": "success"}

@app.delete("/domains/{domain_id}")
def delete_domain(domain_id: int, db: Session = Depends(get_db)):
    db_domain = db.query(DomainDB).filter(DomainDB.id == domain_id).first()
    if db_domain:
        db.delete(db_domain)
        db.commit()
    return {"status": "deleted"}

@app.get("/api/my-signature")
def get_my_signature(request: Request, db: Session = Depends(get_db)):
    user = request.session.get('user')
    if not user: raise HTTPException(status_code=401)
    override = db.query(UserOverrideDB).filter(UserOverrideDB.user_email == user.get('email')).first()
    return {"html_content": override.html_content if override else ""}

@app.post("/api/my-signature")
def save_my_signature(req: OverrideUpdate, request: Request, db: Session = Depends(get_db)):
    user = request.session.get('user')
    if not user: raise HTTPException(status_code=401)
    email = user.get('email')
    override = db.query(UserOverrideDB).filter(UserOverrideDB.user_email == email).first()
    if override: override.html_content = req.html_content
    else: db.add(UserOverrideDB(user_email=email, html_content=req.html_content))
    db.commit()
    return {"status": "success"}

@app.delete("/api/my-signature")
def delete_my_signature(request: Request, db: Session = Depends(get_db)):
    user = request.session.get('user')
    if not user: raise HTTPException(status_code=401)
    email = user.get('email')
    override = db.query(UserOverrideDB).filter(UserOverrideDB.user_email == email).first()
    if override:
        db.delete(override)
        db.commit()
        return {"status": "deleted"}
    return {"status": "not_found"}

@app.get("/api/admin/overrides/{domain_name}")
def get_domain_overrides(domain_name: str, request: Request, db: Session = Depends(get_db)):
    if not is_admin_user(request): raise HTTPException(status_code=403, detail="Admins only")
    overrides = db.query(UserOverrideDB).filter(UserOverrideDB.user_email.endswith(f"@{domain_name}")).all()
    return overrides

@app.post("/api/admin/overrides")
def save_admin_override(req: AdminOverrideSave, request: Request, db: Session = Depends(get_db)):
    if not is_admin_user(request): raise HTTPException(status_code=403, detail="Admins only")
    override = db.query(UserOverrideDB).filter(UserOverrideDB.user_email == req.user_email).first()
    if override: 
        override.html_content = req.html_content
        override.is_disabled = req.is_disabled
    else: 
        db.add(UserOverrideDB(user_email=req.user_email, html_content=req.html_content, is_disabled=req.is_disabled))
    db.commit()
    return {"status": "success"}

@app.delete("/api/admin/overrides/{override_id}")
def delete_admin_override(override_id: int, request: Request, db: Session = Depends(get_db)):
    if not is_admin_user(request): raise HTTPException(status_code=403, detail="Admins only")
    override = db.query(UserOverrideDB).filter(UserOverrideDB.id == override_id).first()
    if override:
        db.delete(override)
        db.commit()
    return {"status": "deleted"}

# ==========================================
# THE RSPAMD COMPILATION ENGINE
# ==========================================
@app.get("/api/signature/{email}")
async def get_rspamd_signature(
    email: str, 
    x_engine_key: Optional[str] = Header(None), 
    db: Session = Depends(get_db)
):
    # --- SECURITY LOCK ---
    expected_key = os.environ.get('ENGINE_API_KEY')
    if not expected_key or x_engine_key != expected_key:
        raise HTTPException(status_code=401, detail="Unauthorized Engine Request")
        
    # 1. Look up Domain Rules
    domain_part = email.split('@')[-1] if '@' in email else ''
    domain_obj = db.query(DomainDB).filter(DomainDB.domain_name == domain_part).first()
    
    if not domain_obj or not domain_obj.is_active:
        return {"html": "", "inject_on_replies": False, "trim_whitespace": True, "strip_device_signatures": False}
        
    # 2. Check for User Override AND KILL SWITCH
    override = db.query(UserOverrideDB).filter(UserOverrideDB.user_email == email).first()
    
    if override and override.is_disabled:
        return {"html": "", "inject_on_replies": False, "trim_whitespace": True, "strip_device_signatures": False}
    
    if override:
        raw_template = override.html_content
    else:
        raw_template = domain_obj.template_html
        
    if not raw_template:
        return {
            "html": "", 
            "inject_on_replies": domain_obj.inject_on_replies,
            "trim_whitespace": domain_obj.trim_whitespace,
            "strip_device_signatures": domain_obj.strip_device_signatures
        }
        
    # 3. Fetch live data from Authentik API
    authentik_url = os.environ.get('AUTHENTIK_URL', '').rstrip('/')
    api_token = os.environ.get('AUTHENTIK_API_TOKEN')
    
    first_name, last_name, title, phone = "", "", "", ""
    
    if authentik_url and api_token:
        headers = {
            "Authorization": f"Bearer {api_token}",
            "Accept": "application/json"
        }
        search_url = f"{authentik_url}/api/v3/core/users/?search={email}"
        
        try:
            async with httpx.AsyncClient(verify=False) as client:
                response = await client.get(search_url, headers=headers, timeout=5.0)
                if response.status_code == 200:
                    data = response.json()
                    results = data.get('results', [])
                    
                    if results:
                        user_data = results[0]
                        name = user_data.get('name', '')
                        name_parts = name.split(' ')
                        first_name = name_parts[0] if name_parts else ''
                        last_name = ' '.join(name_parts[1:]) if len(name_parts) > 1 else ''
                        
                        attributes = user_data.get('attributes', {})
                        
                        title_val = attributes.get('title', [''])
                        phone_val = attributes.get('phone', [''])
                        
                        title = title_val[0] if isinstance(title_val, list) and title_val else str(title_val)
                        phone = phone_val[0] if isinstance(phone_val, list) and phone_val else str(phone_val)
                        
                        if title == "None": title = ""
                        if phone == "None": phone = ""
                else:
                    print(f"Authentik API Error: {response.status_code} - {response.text}")
        except Exception as e:
            print(f"Server-to-Server Authentik Request failed: {e}")
            
    if not first_name:
        first_name = email.split('@')[0].capitalize()
            
    # 4. Compile the HTML using Regex
    parsed = re.sub(r'\{\{\s*first_name\s*\}\}', first_name, raw_template)
    parsed = re.sub(r'\{\{\s*last_name\s*\}\}', last_name, parsed)
    parsed = re.sub(r'\{\{\s*title\s*\}\}', title, parsed)
    parsed = re.sub(r'\{\{\s*phone\s*\}\}', phone, parsed)
    parsed = re.sub(r'\{\{\s*email\s*\}\}', email, parsed)
    parsed = re.sub(r'\{\{\s*domain_name\s*\}\}', domain_part, parsed)
    
    # 5. Deliver to Rspamd
    return {
        "html": parsed,
        "inject_on_replies": domain_obj.inject_on_replies,
        "trim_whitespace": domain_obj.trim_whitespace,
        "strip_device_signatures": domain_obj.strip_device_signatures
    }
