import os
import json
from fastapi import FastAPI, Depends, HTTPException, Request
from fastapi.responses import RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from sqlalchemy import create_engine, Column, Integer, String, Boolean, ForeignKey, Text
from sqlalchemy.orm import declarative_base, sessionmaker, Session
from pydantic import BaseModel
from typing import List, Optional

# New SSO Imports
from dotenv import load_dotenv
from starlette.middleware.sessions import SessionMiddleware
from authlib.integrations.starlette_client import OAuth

load_dotenv() # Loads the .env file we just made

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
    allow_overrides = Column(Boolean, default=True) # New Setting
    template_html = Column(Text, default="<p>Best Regards,</p><p><br></p><p><strong>{{ first_name }} {{ last_name }}</strong></p><p>{{ title }} | {{ domain_name }}</p>") # New Template

class UserOverrideDB(Base):
    __tablename__ = "user_overrides"
    id = Column(Integer, primary_key=True, index=True)
    user_email = Column(String, unique=True, index=True)
    html_content = Column(Text, default="")

Base.metadata.create_all(bind=engine)

# Pydantic Models for API
class DomainCreate(BaseModel):
    domain_name: str
    is_active: bool = True

class DomainUpdate(BaseModel):
    is_active: bool
    allow_overrides: bool
    template_html: str

class OverrideUpdate(BaseModel):
    html_content: str

# 3. FastAPI App Initialization
app = FastAPI(
    title="OpenSigWeave API", 
    version="0.1.0",
    docs_url=None,
    redoc_url=None,
    openapi_url=None
)

# Enable browser sessions for logins
app.add_middleware(SessionMiddleware, secret_key=os.environ.get("SECRET_KEY", "fallback-secret"))

# Configure Authentik OAuth
oauth = OAuth()
oauth.register(
    name='authentik',
    server_metadata_url=f"{os.environ.get('AUTHENTIK_URL')}/application/o/{os.environ.get('AUTHENTIK_SLUG')}/.well-known/openid-configuration",
    client_id=os.environ.get('CLIENT_ID'),
    client_secret=os.environ.get('CLIENT_SECRET'),
    client_kwargs={
        'scope': 'openid email profile attributes'
    }
)

# Set up templates and static files
templates = Jinja2Templates(directory="templates")
app.mount("/branding", StaticFiles(directory="branding"), name="branding")

# Dependency to get the database session
def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

# --- Web UI Routes ---
@app.get("/login")
async def login(request: Request):
    # Natively force the URL to HTTPS, ignoring proxy header confusion
    redirect_uri = request.url_for('auth').replace(scheme='https')
    return await oauth.authentik.authorize_redirect(request, str(redirect_uri))

@app.get("/auth")
async def auth(request: Request):
    # Authentik sends them back here with a token
    try:
        token = await oauth.authentik.authorize_access_token(request)
        user = token.get('userinfo')
        if user:
            request.session['user'] = user
    except Exception as e:
        print(f"Login failed: {e}")
    return RedirectResponse(url='/')

@app.get("/logout")
async def logout(request: Request):
    # 1. Clear the local OpenSigWeave session
    request.session.pop('user', None)
    
    # 2. Redirect to Authentik to kill the master session AND tell it where to return
    authentik_url = os.environ.get('AUTHENTIK_URL')
    slug = os.environ.get('AUTHENTIK_SLUG')
    return_url = str(request.url_for('read_root')).replace('http://', 'https://')
    
    end_session_url = f"{authentik_url}/application/o/{slug}/end-session/?post_logout_redirect_uri={return_url}"
    
    return RedirectResponse(url=end_session_url)

@app.get("/")
def read_root(request: Request):
    user = request.session.get('user')
    
    # THE GATEKEEPER: If not logged in, bounce to Authentik
    if not user:
        return RedirectResponse(url='/login')
        
    # Check groups (Authentik usually passes groups in the profile scope)
    user_groups = user.get('groups', [])
    is_admin = 'signature-admins' in user_groups
    is_user = 'signature-users' in user_groups
    
    if not is_admin and not is_user:
        return templates.TemplateResponse("error.html", {"request": request, "message": "You do not have permission to access the Signature Portal."})

    has_logo = os.path.isfile("branding/logo.png")
    has_favicon = os.path.isfile("branding/favicon.ico")
    
    app_name = "OpenSigWeave"
    settings_path = "branding/settings.json"
    if os.path.isfile(settings_path):
        try:
            with open(settings_path, "r") as f:
                settings = json.load(f)
                if "app_name" in settings:
                    app_name = settings["app_name"]
        except Exception:
            pass
            
    # Ensure user has attributes dictionary, then extract phone and title safely
    attributes = user.get('attributes', {}) if user else {}
    phone = attributes.get('phone', 'Not Set')
    title = attributes.get('title', 'Not Set')

    # Split the name for the frontend variables
    name = user.get('name', '')
    name_parts = name.split(' ')
    first_name = name_parts[0] if name_parts else ''
    last_name = ' '.join(name_parts[1:]) if len(name_parts) > 1 else ''

    authentik_url = os.environ.get('AUTHENTIK_URL', '')
    authentik_settings_url = f"{authentik_url}/if/user/#/settings"
            
    return templates.TemplateResponse("index.html", {
        "request": request, 
        "has_logo": has_logo,
        "has_favicon": has_favicon,
        "app_name": app_name,
        "user": user,
        "is_admin": is_admin,
        "authentik_settings_url": authentik_settings_url,
        "phone": phone,
        "title": title,
        "first_name": first_name,
        "last_name": last_name
    })

# --- API Endpoints: Domains ---

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
    if override:
        override.html_content = req.html_content
    else:
        override = UserOverrideDB(user_email=email, html_content=req.html_content)
        db.add(override)
    db.commit()
    return {"status": "success"}
