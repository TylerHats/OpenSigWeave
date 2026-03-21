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

# 1. Database Setup
SQLALCHEMY_DATABASE_URL = "sqlite:///./opensigweave.db"
# check_same_thread is needed for SQLite in FastAPI
engine = create_engine(SQLALCHEMY_DATABASE_URL, connect_args={"check_same_thread": False})
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()

# 2. Database Models (The Schema we discussed)
class Domain(Base):
    __tablename__ = "domains"

    id = Column(Integer, primary_key=True, index=True)
    domain_name = Column(String, unique=True, index=True, nullable=False)
    html_template = Column(Text, nullable=True)
    plain_template = Column(Text, nullable=True)
    is_active = Column(Boolean, default=True)

class UserOverride(Base):
    __tablename__ = "user_overrides"

    id = Column(Integer, primary_key=True, index=True)
    email = Column(String, unique=True, index=True, nullable=False)
    domain_id = Column(Integer, ForeignKey("domains.id"), nullable=False)
    html_override = Column(Text, nullable=True)
    plain_override = Column(Text, nullable=True)
    is_locked = Column(Boolean, default=False)

# --- Pydantic Schemas (Data Validation) ---

class DomainBase(BaseModel):
    domain_name: str
    html_template: Optional[str] = None
    plain_template: Optional[str] = None
    is_active: bool = True

class DomainCreate(DomainBase):
    pass

class DomainResponse(DomainBase):
    id: int

    class Config:
        from_attributes = True

# Create the tables in the database
Base.metadata.create_all(bind=engine)

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
        'scope': 'openid email profile'
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
    
    # 2. Redirect to Authentik to kill the master session
    authentik_url = os.environ.get('AUTHENTIK_URL')
    slug = os.environ.get('AUTHENTIK_SLUG')
    end_session_url = f"{authentik_url}/application/o/{slug}/end-session/"
    
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
            
    return templates.TemplateResponse("index.html", {
        "request": request, 
        "has_logo": has_logo,
        "has_favicon": has_favicon,
        "app_name": app_name,
        "user": user,
        "is_admin": is_admin
    })

# --- API Endpoints: Domains ---

@app.post("/domains/", response_model=DomainResponse)
def create_domain(domain: DomainCreate, db: Session = Depends(get_db)):
    # Check if domain already exists
    db_domain = db.query(Domain).filter(Domain.domain_name == domain.domain_name).first()
    if db_domain:
        raise HTTPException(status_code=400, detail="Domain already registered")
    
    # Create and save the new domain
    new_domain = Domain(**domain.model_dump())
    db.add(new_domain)
    db.commit()
    db.refresh(new_domain)
    return new_domain

@app.get("/domains/", response_model=List[DomainResponse])
def get_domains(skip: int = 0, limit: int = 100, db: Session = Depends(get_db)):
    domains = db.query(Domain).offset(skip).limit(limit).all()
    return domains

@app.get("/domains/{domain_id}", response_model=DomainResponse)
def get_domain(domain_id: int, db: Session = Depends(get_db)):
    domain = db.query(Domain).filter(Domain.id == domain_id).first()
    if domain is None:
        raise HTTPException(status_code=404, detail="Domain not found")
    return domain
